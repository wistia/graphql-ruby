# frozen_string_literal: true
require "digest/sha2"
require "fileutils"

module GraphQL
  class Schema
    # Merkle-tree fragment cache for schema SDL dumps.
    #
    # Each type gets a per-type content fingerprint computed from its name, fields,
    # and arguments without resolving cross-type references (no ensure_loaded triggered).
    # The schema's cache key is the SHA256 of all sorted type fingerprints (Merkle root).
    #
    # Warm run (nothing changed): returns cached full SDL immediately — no Warden BFS,
    # no ensure_loaded, no AST construction.
    #
    # Partial change: re-renders only changed types, assembles from fragments.
    module CachedDump
      DEFAULT_CACHE_DIR = "tmp/cache/graphql"

      def self.dump_json(schema, context: nil, cache_dir: DEFAULT_CACHE_DIR, **json_options)
        FileUtils.mkdir_p(cache_dir)

        types = dumpable_types(schema)
        fingerprints = compute_fingerprints(types)
        options_key = Digest::SHA256.hexdigest(json_options.sort.map(&:inspect).join)
        merkle_root = Digest::SHA256.hexdigest(fingerprints.values.sort.join)

        cache_path = File.join(cache_dir, "schema_#{merkle_root}_#{options_key}.json")
        return File.read(cache_path) if File.exist?(cache_path)

        result = schema.to_json(context: context, **json_options)

        tmp = "#{cache_path}.#{rand}"
        File.binwrite(tmp, result)
        File.rename(tmp, cache_path)
        result
      end

      def self.dump(schema, context: nil, cache_dir: DEFAULT_CACHE_DIR)
        FileUtils.mkdir_p(File.join(cache_dir, "types"))

        types = dumpable_types(schema)
        fingerprints = compute_fingerprints(types)
        merkle_root = Digest::SHA256.hexdigest(fingerprints.values.sort.join)

        full_cache_path = File.join(cache_dir, "schema_#{merkle_root}.graphql")
        return File.read(full_cache_path) if File.exist?(full_cache_path)

        # Partial / cold path: init the printer once (one Warden BFS) then render
        # only cache-miss types; all others come from the fragment store.
        printer = GraphQL::Schema::Printer.new(schema, context: context)

        # Split the full document into non-type header nodes (schema def, directives)
        # and type definition nodes. Headers are always re-rendered (cheap).
        # Type nodes are individually cached.
        document = printer.instance_variable_get(:@document)
        header_nodes, type_nodes = document.definitions.partition do |node|
          !node.is_a?(GraphQL::Language::Nodes::AbstractNode) ||
            node.class.name !~ /TypeDefinition$/
        end

        header_sdl = header_nodes.map { |n| printer.print(n) }.join("\n\n")

        # For type nodes, prefer the per-type fragment cache; render and cache on miss.
        # We index the already-computed types by graphql_name for O(1) lookup.
        type_map = types.each_with_object({}) { |t, h| h[t.graphql_name] = t }

        type_sdls = type_nodes.sort_by(&:name).map do |node|
          type = type_map[node.name]
          if type
            fp = fingerprints[type]
            fragment_for_node(node, type.graphql_name, fp, printer, cache_dir)
          else
            printer.print(node)
          end
        end

        parts = []
        parts << header_sdl unless header_sdl.empty?
        parts.concat(type_sdls)

        result = parts.join("\n\n") + "\n"

        tmp = "#{full_cache_path}.#{rand}"
        File.binwrite(tmp, result)
        File.rename(tmp, full_cache_path)
        result
      end

      def self.dumpable_types(schema)
        schema.send(:non_introspection_types).values.reject do |type|
          type.kind.scalar? && type.default_scalar?
        end
      end
      private_class_method :dumpable_types

      def self.compute_fingerprints(types)
        types.each_with_object({}) { |type, h| h[type] = type_fingerprint(type) }
      end
      private_class_method :compute_fingerprints

      def self.type_fingerprint(type)
        d = Digest::SHA256.new
        d << type.graphql_name
        d << type.kind.name
        d << type.description.to_s

        case type.kind.name
        when "OBJECT", "INTERFACE"
          type.all_field_definitions.sort_by(&:name).each do |field|
            d << field.name
            # Read raw type expr directly — avoids calling field.type which triggers ensure_loaded
            d << field.instance_variable_get(:@return_type_expr).to_s
            d << field.description.to_s
            d << field.deprecation_reason.to_s
            field.all_argument_definitions.sort_by(&:name).each do |arg|
              d << arg.name
              d << arg.instance_variable_get(:@type_expr).to_s
              d << arg.description.to_s
              d << arg.deprecation_reason.to_s
              d << arg.instance_variable_get(:@default_value).inspect
            end
          end
          if type.kind.object?
            type.interface_type_memberships.sort_by { |m| m.abstract_type.to_s }.each do |m|
              d << m.abstract_type.to_s
            end
          end
        when "UNION"
          type.type_memberships.sort_by { |m| m.object_type.to_s }.each do |m|
            d << m.object_type.to_s
          end
        when "ENUM"
          type.all_enum_value_definitions.sort_by(&:graphql_name).each do |v|
            d << v.graphql_name
            d << v.description.to_s
            d << v.deprecation_reason.to_s
            d << v.value.inspect
          end
        when "INPUT_OBJECT"
          type.all_argument_definitions.sort_by(&:name).each do |arg|
            d << arg.name
            d << arg.instance_variable_get(:@type_expr).to_s
            d << arg.description.to_s
            d << arg.deprecation_reason.to_s
            d << arg.instance_variable_get(:@default_value).inspect
          end
        when "SCALAR"
          d << type.specified_by_url.to_s
        end

        d.hexdigest
      end
      private_class_method :type_fingerprint

      def self.fragment_for_node(node, type_name, fingerprint, printer, cache_dir)
        frag_path = File.join(cache_dir, "types", "#{type_name}_#{fingerprint}.sdl")
        return File.read(frag_path) if File.exist?(frag_path)

        sdl = printer.print(node)
        tmp = "#{frag_path}.#{rand}"
        File.binwrite(tmp, sdl)
        File.rename(tmp, frag_path)
        sdl
      end
      private_class_method :fragment_for_node
    end
  end
end
