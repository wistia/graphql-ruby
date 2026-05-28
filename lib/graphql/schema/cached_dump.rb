# frozen_string_literal: true
require "digest/sha2"
require "etc"
require "fileutils"
require "securerandom"
require "tmpdir"

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

      # Minimum number of types before we bother forking fingerprint workers.
      FINGERPRINT_FORK_THRESHOLD = 20
      # Minimum number of cache-miss nodes before we bother forking render workers.
      RENDER_FORK_THRESHOLD = 4

      FINGERPRINT_CACHE = {}
      private_constant :FINGERPRINT_CACHE

      def self.fingerprints_for(schema, parallel_workers: 1, cache_dir: DEFAULT_CACHE_DIR, watch_dirs: nil)
        cache_key = [schema.object_id, cache_dir, watch_dirs&.sort]
        FINGERPRINT_CACHE[cache_key] ||= compute_and_persist_fingerprints(schema,
          parallel_workers: parallel_workers,
          cache_dir: cache_dir,
          watch_dirs: watch_dirs
        )
      end
      private_class_method :fingerprints_for

      def self.compute_and_persist_fingerprints(schema, parallel_workers:, cache_dir:, watch_dirs:)
        sh = nil

        # Try loading persisted fingerprints from disk (skips ensure_loaded entirely)
        if watch_dirs && !watch_dirs.empty?
          sh = source_hash(watch_dirs)
          fprint_path = File.join(cache_dir, "fingerprints_#{sh}.marshal")
          begin
            persisted = Marshal.load(File.binread(fprint_path))
            types = dumpable_types(schema)
            if persisted.size == types.size
              type_by_name = types.each_with_object({}) { |t, h| h[t.graphql_name] = t }
              fps = persisted.each_with_object({}) { |(name, fp), h|
                t = type_by_name[name]
                h[t] = fp if t
              }
              return fps if fps.size == types.size
            end
          rescue Errno::ENOENT, TypeError, ArgumentError, NameError
            # Cache miss or corrupt file — fall through to compute
          end
        end

        # Full computation (pays ensure_loaded cost)
        fps = compute_fingerprints(dumpable_types(schema), parallel_workers: parallel_workers)

        # Persist to disk for future runs
        if watch_dirs && !watch_dirs.empty?
          sh ||= source_hash(watch_dirs)
          fprint_path = File.join(cache_dir, "fingerprints_#{sh}.marshal")
          by_name = fps.each_with_object({}) { |(t, fp), h| h[t.graphql_name] = fp }
          tmp = "#{fprint_path}.#{Process.pid}.#{SecureRandom.hex(8)}"
          File.binwrite(tmp, Marshal.dump(by_name))
          File.rename(tmp, fprint_path)
        end

        fps
      end
      private_class_method :compute_and_persist_fingerprints

      def self.clear_cache
        FINGERPRINT_CACHE.clear
      end

      # Attempt to return a cached SDL file without loading any schema types.
      # Only possible when watch_dirs is set (so we can derive the merkle root from
      # the on-disk fingerprint marshal file without calling ensure_loaded).
      # Returns the cached String on hit, nil on miss.
      def self.fast_path_cached_sdl(cache_dir, watch_dirs, suffix_key, extension)
        return nil unless watch_dirs && !watch_dirs.empty?

        sh = source_hash(watch_dirs)
        fprint_path = File.join(cache_dir, "fingerprints_#{sh}.marshal")
        persisted = Marshal.load(File.binread(fprint_path))
        merkle_root = Digest::SHA256.hexdigest(
          persisted.sort_by { |name, _| name }.map { |name, fp| "#{name}:#{fp}" }.join
        )
        if suffix_key
          cache_path = File.join(cache_dir, "schema_#{merkle_root}_#{suffix_key}#{extension}")
        else
          cache_path = File.join(cache_dir, "schema_#{merkle_root}#{extension}")
        end
        File.read(cache_path, encoding: Encoding::UTF_8)
      rescue Errno::ENOENT, TypeError, ArgumentError, NameError
        nil
      end
      private_class_method :fast_path_cached_sdl

      def self.compute_merkle_root(fingerprints)
        Digest::SHA256.hexdigest(
          fingerprints.sort_by { |t, _| t.graphql_name }.map { |t, fp| "#{t.graphql_name}:#{fp}" }.join
        )
      end
      private_class_method :compute_merkle_root

      # Compute a SHA256 of all .rb file contents under the given directories.
      # Used as a stable cache key for persisted fingerprints that survives git checkouts
      # (which reset mtimes to the current time, making mtime-based keys unreliable in CI).
      def self.source_hash(watch_dirs)
        d = Digest::SHA256.new
        # Sort + uniq after flat_map so overlapping watch_dirs don't double-hash files.
        # Coerce to Array so a caller who accidentally passes a String gets a clear error
        # from Dir.glob rather than iterating String characters.
        dirs = Array(watch_dirs)
        paths = dirs.flat_map { |dir| Dir.glob("#{dir}/**/*.rb") }.sort.uniq
        paths.each do |path|
          # Read content before touching the digest: if the file vanishes between
          # glob and read (TOCTOU), rescue before anything is mixed into the hash.
          content = File.binread(path) rescue next
          d << path << "\x00" << content << "\x00"
        end
        d.hexdigest
      end
      private_class_method :source_hash

      def self.dump_json(schema, context: nil, cache_dir: DEFAULT_CACHE_DIR, parallel_workers: [Etc.nprocessors, 8].min, watch_dirs: nil, **json_options)
        FileUtils.mkdir_p(cache_dir)

        options_key = Digest::SHA256.hexdigest(json_options.sort.map(&:inspect).join)

        # Fast path: if watch_dirs is set, try to derive the merkle root purely from
        # the on-disk fingerprint file — no ensure_loaded, no type loading at all.
        if (sdl = fast_path_cached_sdl(cache_dir, watch_dirs, options_key, ".json"))
          return sdl
        end

        fingerprints = fingerprints_for(schema, parallel_workers: parallel_workers, cache_dir: cache_dir, watch_dirs: watch_dirs)
        merkle_root = compute_merkle_root(fingerprints)

        cache_path = File.join(cache_dir, "schema_#{merkle_root}_#{options_key}.json")
        cached = File.read(cache_path, encoding: Encoding::UTF_8) rescue nil
        return cached if cached

        result = schema.to_json(context: context, **json_options)

        tmp = "#{cache_path}.#{Process.pid}.#{SecureRandom.hex(8)}"
        File.binwrite(tmp, result)
        File.rename(tmp, cache_path)
        result
      end

      def self.dump(schema, context: nil, cache_dir: DEFAULT_CACHE_DIR, parallel_workers: [Etc.nprocessors, 8].min, watch_dirs: nil)
        FileUtils.mkdir_p(File.join(cache_dir, "types"))

        # Fast path: if watch_dirs is set, try to derive the merkle root purely from
        # the on-disk fingerprint file — no ensure_loaded, no type loading at all.
        if (sdl = fast_path_cached_sdl(cache_dir, watch_dirs, nil, ".graphql"))
          return sdl
        end

        fingerprints = fingerprints_for(schema, parallel_workers: parallel_workers, cache_dir: cache_dir, watch_dirs: watch_dirs)
        types = fingerprints.keys
        merkle_root = compute_merkle_root(fingerprints)

        full_cache_path = File.join(cache_dir, "schema_#{merkle_root}.graphql")
        cached = File.read(full_cache_path, encoding: Encoding::UTF_8) rescue nil
        return cached if cached

        # Partial / cold path: init the printer once (one Warden BFS) then render
        # only cache-miss types; all others come from the fragment store.
        printer = GraphQL::Schema::Printer.new(schema, context: context)

        # Split the full document into non-type header nodes (schema def, directives)
        # and type definition nodes. Headers are always re-rendered (cheap).
        # Type nodes are individually cached.
        document = printer.instance_variable_get(:@document)
        header_nodes, type_nodes = document.definitions.partition do |node|
          node.class.name !~ /TypeDefinition$/
        end

        header_sdl = header_nodes.map { |n| printer.print(n) }.join("\n\n")

        # For type nodes, prefer the per-type fragment cache; render and cache on miss.
        # We index the already-computed types by graphql_name for O(1) lookup.
        type_map = types.each_with_object({}) { |t, h| h[t.graphql_name] = t }

        sorted_type_nodes = type_nodes.sort_by(&:name)

        # Identify cache misses up front so we can decide whether to parallelize.
        hits = {}
        misses = []  # array of [index_in_sorted, node, type_name, fingerprint]

        sorted_type_nodes.each_with_index do |node, idx|
          type = type_map[node.name]
          if type
            fp = fingerprints[type]
            frag_path = File.join(cache_dir, "types", "#{type.graphql_name}_#{fp}.sdl")
            begin
              hits[idx] = File.read(frag_path, encoding: Encoding::UTF_8)
            rescue Errno::ENOENT
              misses << [idx, node, type.graphql_name, fp]
            end
          else
            # Node has no type in our map — will be rendered inline (no caching).
            # Treat as a special hit with a nil fragment path.
            hits[idx] = :inline
          end
        end

        # Render cache misses — parallel if there are enough of them.
        if misses.size >= RENDER_FORK_THRESHOLD && parallel_workers > 1
          rendered_misses = parallel_render_fragments(misses, cache_dir, parallel_workers)
        else
          rendered_misses = {}
          misses.each do |idx, node, type_name, fp|
            rendered_misses[idx] = fragment_for_node(node, type_name, fp, printer, cache_dir)
          end
        end

        misses.each do |idx, node, type_name, _fp|
          raise "CachedDump: failed to render type '#{type_name}' (node index #{idx})" if rendered_misses[idx].nil?
        end

        # Assemble final SDL in sorted order.
        type_sdls = sorted_type_nodes.each_with_index.map do |node, idx|
          if hits.key?(idx)
            val = hits[idx]
            if val == :inline
              printer.print(node)
            else
              val
            end
          else
            rendered_misses[idx]
          end
        end

        parts = []
        parts << header_sdl unless header_sdl.empty?
        parts.concat(type_sdls)

        result = parts.join("\n\n") + "\n"

        tmp = "#{full_cache_path}.#{Process.pid}.#{SecureRandom.hex(8)}"
        File.binwrite(tmp, result)
        File.rename(tmp, full_cache_path)
        result
      end

      def self.dumpable_types(schema)
        # non_introspection_types values can be Arrays (multiple definitions sharing a name,
        # used with Schema::Visibility profiles). Flatten to get individual type modules.
        base = schema.send(:non_introspection_types).values.flatten
        extra = Array(schema.extra_types).flatten
        # Deduplicate by graphql_name (not object identity) so same-name different-object
        # duplicates from extra_types don't produce two entries with the same name in the
        # persisted fingerprint file (which would corrupt the size-equality check).
        all = (base + extra).uniq { |t| t.graphql_name }
        all.reject { |type| type.kind.scalar? && type.default_scalar? }
      end
      private_class_method :dumpable_types

      # Compute fingerprints, optionally in parallel.
      # Returns a Hash[type => hex_digest].
      def self.compute_fingerprints(types, parallel_workers: 1)
        if parallel_workers > 1 && types.size >= FINGERPRINT_FORK_THRESHOLD
          parallel_fingerprints(types, parallel_workers)
        else
          types.each_with_object({}) { |type, h| h[type] = type_fingerprint(type) }
        end
      end
      private_class_method :compute_fingerprints

      # Fork N workers to compute fingerprints in parallel.
      # Each worker writes its marshaled result to a temp file and sends the path
      # through the pipe (a short string that never overflows the 64KB pipe buffer).
      # Parent reassembles the full Hash[type => hex_digest].
      def self.parallel_fingerprints(types, num_workers)
        # fork(2) is unsafe in multi-threaded processes: mutexes held by other threads are
        # copied locked into the child with no owner, causing deadlocks. Fall back to serial
        # if more than one thread is live (e.g. Puma worker threads, AR connection pool).
        if Thread.list.size > 1
          return types.each_with_object({}) { |type, h| h[type] = type_fingerprint(type) }
        end

        batches = partition_into_batches(types, num_workers)
        results_by_name = {}

        workers = batches.map do |batch|
          rd, wr = IO.pipe
          pid = begin
            fork do
              rd.close
              begin
                result = {}
                batch.each { |t| result[t.graphql_name] = type_fingerprint(t) }
                tmp_result = File.join(Dir.tmpdir, "cached_dump_fp.#{Process.pid}.#{SecureRandom.hex(8)}")
                File.binwrite(tmp_result, Marshal.dump(result))
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
            # Only raise if the worker produced no path — a SIGKILL after the path was
            # written still delivers valid results, so check tmp_path first.
            if tmp_path.empty?
              raise "CachedDump: fingerprint worker (pid #{w[:pid]}) produced no result: #{worker_exit_description(status)}"
            end
            Marshal.load(File.binread(tmp_path)).each { |name, fp| results_by_name[name] = fp }
          rescue => e
            first_error ||= e
          ensure
            File.unlink(tmp_path) rescue nil
          end
        end
        raise first_error if first_error

        # Rebuild the Hash keyed by type object (not name) to match non-parallel shape.
        type_by_name = types.each_with_object({}) { |t, h| h[t.graphql_name] = t }
        results_by_name.each_with_object({}) do |(name, fp), h|
          t = type_by_name[name]
          h[t] = fp if t
        end
      end
      private_class_method :parallel_fingerprints

      # Fork N workers to render cache-miss SDL fragments and write them atomically.
      # Returns a Hash[idx => sdl_string] for all entries in +misses+.
      # Each miss entry is [idx, node, type_name, fingerprint].
      def self.parallel_render_fragments(misses, cache_dir, num_workers)
        if Thread.list.size > 1
          rendered = {}
          misses.each { |idx, node, type_name, fp| rendered[idx] = fragment_for_node(node, type_name, fp, GraphQL::Language::Printer.new, cache_dir) }
          return rendered
        end

        batches = partition_into_batches(misses, num_workers)
        results = {}

        workers = batches.map do |batch|
          rd, wr = IO.pipe
          pid = begin
            fork do
              rd.close
              begin
                lang_printer = GraphQL::Language::Printer.new
                batch_result = {}
                batch.each do |idx, node, type_name, fp|
                  frag_path = File.join(cache_dir, "types", "#{type_name}_#{fp}.sdl")
                  # Another process may have already written this fragment — check first.
                  begin
                    sdl = File.read(frag_path, encoding: Encoding::UTF_8)
                  rescue Errno::ENOENT
                    sdl = lang_printer.print(node)
                    tmp = "#{frag_path}.#{Process.pid}.#{SecureRandom.hex(8)}"
                    File.binwrite(tmp, sdl)
                    File.rename(tmp, frag_path)
                  end
                  batch_result[idx] = sdl
                end
                tmp_result = File.join(Dir.tmpdir, "cached_dump_render.#{Process.pid}.#{SecureRandom.hex(8)}")
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
              raise "CachedDump: render worker (pid #{w[:pid]}) produced no result: #{worker_exit_description(status)}"
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
      private_class_method :parallel_render_fragments

      # Divide +items+ into at most +n+ roughly equal batches (Array of Arrays).
      def self.partition_into_batches(items, n)
        return [items] if n <= 1 || items.empty?
        actual = [n, items.size].min
        items.each_slice((items.size.to_f / actual).ceil).to_a
      end
      private_class_method :partition_into_batches

      def self.hash_directives(d, directives)
        directives.sort_by(&:graphql_name).each do |dir|
          d << dir.graphql_name
          d << "\x00"
          dir.arguments.keyword_arguments.sort.each do |key, val|
            d << key.to_s
            d << "\x00"
            d << val.inspect
            d << "\x00"
          end
        end
      end
      private_class_method :hash_directives

      # Return a stable string for a raw type expression ivar (@return_type_expr / @type_expr).
      # When the ivar holds a Class/Module (already resolved), use .graphql_name which is stable
      # across processes. When it holds a String/Symbol/Array (unresolved expr), .to_s is fine.
      def self.stable_type_expr(expr)
        case expr
        when Module
          expr.respond_to?(:graphql_name) ? expr.graphql_name : expr.name.to_s
        when Array
          expr.map { |e| stable_type_expr(e) }.inspect
        else
          expr.to_s
        end
      end
      private_class_method :stable_type_expr

      def self.type_fingerprint(type)
        d = Digest::SHA256.new
        d << type.graphql_name
        d << "\x00"
        d << type.kind.name
        d << "\x00"
        d << type.description.to_s
        d << "\x00"
        d << type.comment.to_s
        d << "\x00"
        hash_directives(d, type.directives)

        case type.kind.name
        when "OBJECT", "INTERFACE"
          type.all_field_definitions.sort_by(&:name).each do |field|
            field.ensure_loaded
            d << field.name
            d << "\x00"
            # Read raw type expr directly — avoids calling field.type which triggers ensure_loaded.
            # Use stable_type_expr to handle already-resolved Class objects (avoid #<Class:0xADDR>).
            # For resolver-backed fields, @return_type_expr is nil on the field; fall back to the
            # resolver class's type_expr and null (which carry the actual declared type).
            type_expr = field.instance_variable_get(:@return_type_expr)
            type_null  = field.instance_variable_get(:@return_type_null)
            if type_expr.nil? && (rc = field.instance_variable_get(:@resolver_class))
              type_expr = rc.type_expr
              type_null = rc.null if type_null.nil?
            end
            d << stable_type_expr(type_expr)
            d << "\x00"
            d << type_null.inspect
            d << "\x00"
            d << field.description.to_s
            d << "\x00"
            d << field.comment.to_s
            d << "\x00"
            d << field.deprecation_reason.to_s
            d << "\x00"
            hash_directives(d, field.directives)
            field.all_argument_definitions.sort_by(&:name).each do |arg|
              d << arg.name
              d << "\x00"
              d << stable_type_expr(arg.instance_variable_get(:@type_expr))
              d << "\x00"
              d << arg.instance_variable_get(:@null).inspect
              d << "\x00"
              d << arg.description.to_s
              d << "\x00"
              d << arg.comment.to_s
              d << "\x00"
              d << arg.deprecation_reason.to_s
              d << "\x00"
              d << (arg.default_value? ? arg.instance_variable_get(:@default_value).inspect : "")
              d << "\x00"
              hash_directives(d, arg.directives)
            end
          end
          type.interface_type_memberships.sort_by { |m| m.abstract_type.graphql_name }.each do |m|
            d << m.abstract_type.graphql_name
            d << "\x00"
          end
        when "UNION"
          type.type_memberships.sort_by { |m| m.object_type.graphql_name }.each do |m|
            d << m.object_type.graphql_name
            d << "\x00"
          end
        when "ENUM"
          type.all_enum_value_definitions.sort_by(&:graphql_name).each do |v|
            d << v.graphql_name
            d << "\x00"
            d << v.description.to_s
            d << "\x00"
            d << v.comment.to_s
            d << "\x00"
            d << v.deprecation_reason.to_s
            d << "\x00"
            hash_directives(d, v.directives)
          end
        when "INPUT_OBJECT"
          type.all_argument_definitions.sort_by(&:name).each do |arg|
            d << arg.name
            d << "\x00"
            d << stable_type_expr(arg.instance_variable_get(:@type_expr))
            d << "\x00"
            d << arg.instance_variable_get(:@null).inspect
            d << "\x00"
            d << arg.description.to_s
            d << "\x00"
            d << arg.comment.to_s
            d << "\x00"
            d << arg.deprecation_reason.to_s
            d << "\x00"
            d << (arg.default_value? ? arg.instance_variable_get(:@default_value).inspect : "")
            d << "\x00"
            hash_directives(d, arg.directives)
          end
        when "SCALAR"
          d << type.specified_by_url.to_s
          d << "\x00"
        end

        d.hexdigest
      end
      private_class_method :type_fingerprint

      def self.worker_exit_description(status)
        if status.exitstatus
          "exit status #{status.exitstatus}"
        elsif status.termsig
          sig = Signal.signame(status.termsig) rescue status.termsig.to_s
          "killed by signal #{sig} (#{status.termsig})"
        else
          "unknown exit"
        end
      end
      private_class_method :worker_exit_description

      def self.fragment_for_node(node, type_name, fingerprint, printer, cache_dir)
        frag_path = File.join(cache_dir, "types", "#{type_name}_#{fingerprint}.sdl")
        cached = File.read(frag_path, encoding: Encoding::UTF_8) rescue nil
        return cached if cached

        sdl = printer.print(node)
        tmp = "#{frag_path}.#{Process.pid}.#{SecureRandom.hex(8)}"
        File.binwrite(tmp, sdl)
        File.rename(tmp, frag_path)
        sdl
      end
      private_class_method :fragment_for_node
    end
  end
end
