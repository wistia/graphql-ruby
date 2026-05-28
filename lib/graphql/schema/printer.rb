# frozen_string_literal: true
require "etc"
require "securerandom"
require "tmpdir"

module GraphQL
  class Schema
    # Used to convert your {GraphQL::Schema} to a GraphQL schema string
    #
    # @example print your schema to standard output (via helper)
    #   puts GraphQL::Schema::Printer.print_schema(MySchema)
    #
    # @example print your schema to standard output
    #   puts GraphQL::Schema::Printer.new(MySchema).print_schema
    #
    # @example print a single type to standard output
    #   class Types::Query < GraphQL::Schema::Object
    #     description "The query root of this schema"
    #
    #     field :post, Types::Post, null: true
    #   end
    #
    #   class Types::Post < GraphQL::Schema::Object
    #     description "A blog post"
    #
    #     field :id, ID, null: false
    #     field :title, String, null: false
    #     field :body, String, null: false
    #   end
    #
    #   class MySchema < GraphQL::Schema
    #     query(Types::Query)
    #   end
    #
    #   printer = GraphQL::Schema::Printer.new(MySchema)
    #   puts printer.print_type(Types::Post)
    #
    class Printer < GraphQL::Language::Printer
      attr_reader :schema, :warden

      # @param schema [GraphQL::Schema]
      # @param context [Hash]
      # @param introspection [Boolean] Should include the introspection types in the string?
      # @param parallel_workers [Integer] Number of fork workers for rendering type nodes.
      #   When > 1 and there are enough type nodes, rendering is parallelized via fork+pipe.
      #   Defaults to 1 (serial).
      def initialize(schema, context: nil, introspection: false, parallel_workers: 1)
        @document_from_schema = GraphQL::Language::DocumentFromSchemaDefinition.new(
          schema,
          context: context,
          include_introspection_types: introspection,
        )

        @document = @document_from_schema.document
        @schema = schema
        @parallel_workers = parallel_workers
      end

      # Return the GraphQL schema string for the introspection type system
      def self.print_introspection_schema
        query_root = Class.new(GraphQL::Schema::Object) do
          graphql_name "Root"
          field :throwaway_field, String
          def self.visible?(ctx)
            false
          end
        end
        schema = Class.new(GraphQL::Schema) {
          query(query_root)
          use GraphQL::Schema::Visibility
          def self.visible?(member, _ctx)
            member.graphql_name != "Root"
          end
        }

        introspection_schema_ast = GraphQL::Language::DocumentFromSchemaDefinition.new(
          schema,
          include_introspection_types: true,
          include_built_in_directives: true,
        ).document

        introspection_schema_ast.to_query_string(printer: IntrospectionPrinter.new)
      end

      # Return a GraphQL schema string for the defined types in the schema
      # @param schema [GraphQL::Schema]
      # @param context [Hash]
      # @param only [<#call(member, ctx)>]
      # @param except [<#call(member, ctx)>]
      def self.print_schema(schema, **args)
        printer = new(schema, **args)
        printer.print_schema
      end

      # Return a GraphQL schema string for the defined types in the schema.
      # When @parallel_workers > 1, type definition nodes are rendered in forked workers.
      def print_schema
        workers = @parallel_workers || 1
        if workers > 1
          parallel_print_schema(workers)
        else
          print(@document) + "\n"
        end
      end

      def print_type(type)
        node = @document_from_schema.build_type_definition_node(type)
        print(node)
      end

      class IntrospectionPrinter < GraphQL::Language::Printer
        def print_schema_definition(schema)
          print_string("schema {\n  query: Root\n}")
        end
      end

      private

      # Minimum number of type nodes before we bother forking render workers.
      PARALLEL_TYPE_THRESHOLD = 4

      # Render the document in parallel: header nodes serially in the parent,
      # type definition nodes distributed across fork workers.
      def parallel_print_schema(num_workers)
        header_nodes, type_nodes = @document.definitions.partition do |node|
          !node.is_a?(GraphQL::Language::Nodes::AbstractNode) ||
            node.class.name !~ /TypeDefinition$/
        end

        # Render header nodes (schema def, directives) serially — they're cheap.
        header_parts = header_nodes.map { |n| print(n) }

        if type_nodes.size < PARALLEL_TYPE_THRESHOLD || num_workers <= 1
          # Not worth forking — render serially.
          type_parts_by_index = type_nodes.each_with_index.map { |n, i| [i, print(n)] }.to_h
        else
          type_parts_by_index = fork_render_nodes(type_nodes, num_workers)
        end

        type_parts = type_nodes.each_index.map { |i| type_parts_by_index[i] }

        parts = header_parts + type_parts
        parts.join("\n\n") + "\n"
      end

      # Fork +num_workers+ processes to render slices of +nodes+.
      # Each worker writes its marshaled result to a temp file and sends the path
      # through the pipe (a short string that never overflows the 64KB pipe buffer).
      # Returns a Hash[index => rendered_string] covering all nodes.
      def fork_render_nodes(nodes, num_workers)
        actual_workers = [num_workers, nodes.size].min
        slice_size = (nodes.size.to_f / actual_workers).ceil

        # Build index-tagged batches: [[idx, node], ...]
        indexed = nodes.each_with_index.map { |n, i| [i, n] }
        batches = indexed.each_slice(slice_size).to_a

        results = {}

        workers = batches.map do |batch|
          rd, wr = IO.pipe
          pid = begin
            fork do
              rd.close
              begin
                lang_printer = GraphQL::Language::Printer.new
                batch_result = {}
                batch.each do |idx, node|
                  batch_result[idx] = lang_printer.print(node)
                end
                tmp_result = File.join(Dir.tmpdir, "printer_render.#{Process.pid}.#{SecureRandom.hex(8)}")
                File.binwrite(tmp_result, Marshal.dump(batch_result))
                wr.write(tmp_result)
              ensure
                wr.close
                exit!(0)
              end
            end
          rescue
            wr.close
            raise
          end
          wr.close
          { pid: pid, rd: rd }
        end

        first_error = nil
        workers.each do |w|
          tmp_path = w[:rd].read
          w[:rd].close
          _pid, status = Process.waitpid2(w[:pid])
          begin
            if tmp_path.empty?
              raise "Schema::Printer: render worker (pid #{w[:pid]}) produced no result: #{worker_exit_description(status)}"
            end
            Marshal.load(File.binread(tmp_path)).each { |idx, sdl| results[idx] = sdl }
          rescue => e
            first_error ||= e
          ensure
            File.unlink(tmp_path) rescue nil
          end
        end
        raise first_error if first_error

        results
      end

      def worker_exit_description(status)
        if status.exitstatus
          "exit status #{status.exitstatus}"
        elsif status.termsig
          sig = Signal.signame(status.termsig) rescue status.termsig.to_s
          "killed by signal #{sig} (#{status.termsig})"
        else
          "unknown exit"
        end
      end
    end
  end
end
