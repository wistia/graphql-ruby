# frozen_string_literal: true
require "spec_helper"
require "graphql/schema/cached_dump"
require "tmpdir"
require "fileutils"

describe GraphQL::Schema::CachedDump do
  def fp_cache
    GraphQL::Schema::CachedDump.send(:const_get, :FINGERPRINT_CACHE)
  end

  before do
    fp_cache.clear
  end

  # Shared test schema with objects, interfaces, enums, input objects, unions, scalars
  def build_test_schema
    node_iface = Module.new {
      include GraphQL::Schema::Interface
      graphql_name "Node"
      field :id, GraphQL::Types::ID, null: false
    }

    status_enum = Class.new(GraphQL::Schema::Enum) {
      graphql_name "Status"
      description "Publication status"
      value "DRAFT"
      value "PUBLISHED"
      value "ARCHIVED", deprecation_reason: "Use PUBLISHED"
    }

    tag_input = Class.new(GraphQL::Schema::InputObject) {
      graphql_name "TagInput"
      description "Input for a tag"
      argument :name, String, required: true
      argument :color, String, required: false, default_value: "blue"
    }

    post_type = Class.new(GraphQL::Schema::Object) {
      graphql_name "Post"
      description "A blog post"
      implements node_iface
      field :id, GraphQL::Types::ID, null: false
      field :title, String, null: false
      field :body, String, null: true
      field :status, status_enum, null: false
      field :views, GraphQL::Types::Int, null: false, deprecation_reason: "Use analytics"
    }

    comment_type = Class.new(GraphQL::Schema::Object) {
      graphql_name "Comment"
      description "A comment"
      implements node_iface
      field :id, GraphQL::Types::ID, null: false
      field :text, String, null: false
    }

    content_union = Class.new(GraphQL::Schema::Union) {
      graphql_name "Content"
      description "Any piece of content"
      possible_types post_type, comment_type
    }

    url_scalar = Class.new(GraphQL::Schema::Scalar) {
      graphql_name "URL"
      specified_by_url "https://url.spec.whatwg.org/"
    }

    query_type = Class.new(GraphQL::Schema::Object) {
      graphql_name "Query"
      description "The root query type"
      field :node, node_iface do
        argument :id, GraphQL::Types::ID, required: true, description: "Node ID"
      end
      field :post, post_type do
        argument :id, GraphQL::Types::ID, required: true
        argument :tag, tag_input, required: false
      end
      field :search, [content_union], null: true do
        argument :query, String, required: true
        argument :limit, GraphQL::Types::Int, required: false, default_value: 10
      end
      field :site_url, url_scalar, null: true
    }

    mutation_type = Class.new(GraphQL::Schema::Object) {
      graphql_name "Mutation"
      field :create_post, post_type do
        argument :title, String, required: true
        argument :tag, tag_input, required: false
      end
    }

    Class.new(GraphQL::Schema) {
      query query_type
      mutation mutation_type
      extra_types content_union
    }
  end

  describe "dump (SDL)" do
    it "matches to_definition on cold run" do
      schema = build_test_schema
      Dir.mktmpdir do |dir|
        result = GraphQL::Schema::CachedDump.dump(schema, cache_dir: dir)
        assert_equal schema.to_definition, result
      end
    end

    it "matches to_definition on warm run" do
      schema = build_test_schema
      Dir.mktmpdir do |dir|
        GraphQL::Schema::CachedDump.dump(schema, cache_dir: dir)
        fp_cache.clear
        result = GraphQL::Schema::CachedDump.dump(schema, cache_dir: dir)
        assert_equal schema.to_definition, result
      end
    end
  end

  describe "dump_json" do
    it "matches to_json on cold run" do
      schema = build_test_schema
      Dir.mktmpdir do |dir|
        result = GraphQL::Schema::CachedDump.dump_json(schema, cache_dir: dir)
        assert_equal schema.to_json, result
      end
    end

    it "matches to_json on warm run" do
      schema = build_test_schema
      Dir.mktmpdir do |dir|
        GraphQL::Schema::CachedDump.dump_json(schema, cache_dir: dir)
        fp_cache.clear
        result = GraphQL::Schema::CachedDump.dump_json(schema, cache_dir: dir)
        assert_equal schema.to_json, result
      end
    end
  end

  describe "cache invalidation" do
    it "changing a field description changes the fingerprint and produces updated SDL" do
      Dir.mktmpdir do |dir|
        q_v1 = Class.new(GraphQL::Schema::Object) {
          graphql_name "Query"
          field :name, String, null: true, description: "original description"
        }
        schema_v1 = Class.new(GraphQL::Schema) { query q_v1 }

        q_v2 = Class.new(GraphQL::Schema::Object) {
          graphql_name "Query"
          field :name, String, null: true, description: "updated description"
        }
        schema_v2 = Class.new(GraphQL::Schema) { query q_v2 }

        GraphQL::Schema::CachedDump.dump(schema_v1, cache_dir: dir)
        fp_cache.clear
        result_v2 = GraphQL::Schema::CachedDump.dump(schema_v2, cache_dir: dir)

        query_sdl_files = Dir.glob("#{dir}/types/Query_*.sdl")
        assert_equal 2, query_sdl_files.length
        assert_includes result_v2, "updated description"
        refute_includes result_v2, "original description"
      end
    end

    it "changing a field nullability invalidates the fragment" do
      Dir.mktmpdir do |dir|
        q_v1 = Class.new(GraphQL::Schema::Object) {
          graphql_name "Query"
          field :name, String, null: true
        }
        schema_v1 = Class.new(GraphQL::Schema) { query q_v1 }

        q_v2 = Class.new(GraphQL::Schema::Object) {
          graphql_name "Query"
          field :name, String, null: false
        }
        schema_v2 = Class.new(GraphQL::Schema) { query q_v2 }

        GraphQL::Schema::CachedDump.dump(schema_v1, cache_dir: dir)
        fp_cache.clear
        result_v2 = GraphQL::Schema::CachedDump.dump(schema_v2, cache_dir: dir)

        assert_equal 2, Dir.glob("#{dir}/types/Query_*.sdl").length
        assert_includes result_v2, "name: String!"
      end
    end

    it "adding a field invalidates that type's fragment" do
      Dir.mktmpdir do |dir|
        post_v1 = Class.new(GraphQL::Schema::Object) {
          graphql_name "Post"
          field :title, String, null: false
        }
        q = Class.new(GraphQL::Schema::Object) {
          graphql_name "Query"
          field :post, post_v1
        }
        schema_v1 = Class.new(GraphQL::Schema) { query q }

        post_v2 = Class.new(GraphQL::Schema::Object) {
          graphql_name "Post"
          field :title, String, null: false
          field :body, String, null: true
        }
        q2 = Class.new(GraphQL::Schema::Object) {
          graphql_name "Query"
          field :post, post_v2
        }
        schema_v2 = Class.new(GraphQL::Schema) { query q2 }

        GraphQL::Schema::CachedDump.dump(schema_v1, cache_dir: dir)
        fp_cache.clear
        result_v2 = GraphQL::Schema::CachedDump.dump(schema_v2, cache_dir: dir)

        assert_equal 2, Dir.glob("#{dir}/types/Post_*.sdl").length
        assert_includes result_v2, "body: String"
      end
    end

    it "adding an enum value invalidates the enum's fragment" do
      Dir.mktmpdir do |dir|
        enum_v1 = Class.new(GraphQL::Schema::Enum) {
          graphql_name "Color"
          value "RED"
          value "BLUE"
        }
        q = Class.new(GraphQL::Schema::Object) {
          graphql_name "Query"
          field :color, enum_v1, null: true
        }
        schema_v1 = Class.new(GraphQL::Schema) { query q }

        enum_v2 = Class.new(GraphQL::Schema::Enum) {
          graphql_name "Color"
          value "RED"
          value "BLUE"
          value "GREEN"
        }
        q2 = Class.new(GraphQL::Schema::Object) {
          graphql_name "Query"
          field :color, enum_v2, null: true
        }
        schema_v2 = Class.new(GraphQL::Schema) { query q2 }

        GraphQL::Schema::CachedDump.dump(schema_v1, cache_dir: dir)
        fp_cache.clear
        result_v2 = GraphQL::Schema::CachedDump.dump(schema_v2, cache_dir: dir)

        assert_equal 2, Dir.glob("#{dir}/types/Color_*.sdl").length
        assert_includes result_v2, "GREEN"
      end
    end

    it "changing a union member set invalidates the union's fragment" do
      Dir.mktmpdir do |dir|
        type_a = Class.new(GraphQL::Schema::Object) {
          graphql_name "TypeA"
          field :id, GraphQL::Types::ID, null: false
        }
        type_b = Class.new(GraphQL::Schema::Object) {
          graphql_name "TypeB"
          field :id, GraphQL::Types::ID, null: false
        }
        type_c = Class.new(GraphQL::Schema::Object) {
          graphql_name "TypeC"
          field :id, GraphQL::Types::ID, null: false
        }

        union_v1 = Class.new(GraphQL::Schema::Union) {
          graphql_name "MyUnion"
          possible_types type_a, type_b
        }
        q = Class.new(GraphQL::Schema::Object) {
          graphql_name "Query"
          field :thing, union_v1, null: true
        }
        schema_v1 = Class.new(GraphQL::Schema) { query q }

        union_v2 = Class.new(GraphQL::Schema::Union) {
          graphql_name "MyUnion"
          possible_types type_a, type_b, type_c
        }
        q2 = Class.new(GraphQL::Schema::Object) {
          graphql_name "Query"
          field :thing, union_v2, null: true
        }
        schema_v2 = Class.new(GraphQL::Schema) { query q2 }

        GraphQL::Schema::CachedDump.dump(schema_v1, cache_dir: dir)
        fp_cache.clear
        result_v2 = GraphQL::Schema::CachedDump.dump(schema_v2, cache_dir: dir)

        assert_equal 2, Dir.glob("#{dir}/types/MyUnion_*.sdl").length
        assert_includes result_v2, "TypeC"
      end
    end
  end

  describe "cache structure" do
    it "creates per-type fragment files" do
      schema = build_test_schema
      Dir.mktmpdir do |dir|
        GraphQL::Schema::CachedDump.dump(schema, cache_dir: dir)
        sdl_files = Dir.glob("#{dir}/types/*.sdl")
        refute_empty sdl_files
        sdl_files.each do |path|
          assert_match(/\A[A-Za-z_][A-Za-z0-9_]*_[0-9a-f]{64}\.sdl\z/, File.basename(path))
        end
      end
    end

    it "creates a full schema cache file" do
      schema = build_test_schema
      Dir.mktmpdir do |dir|
        GraphQL::Schema::CachedDump.dump(schema, cache_dir: dir)
        full_files = Dir.glob("#{dir}/schema_*.graphql")
        assert_equal 1, full_files.length
        assert_match(/\Aschema_[0-9a-f]{64}\.graphql\z/, File.basename(full_files.first))
      end
    end

    it "warm run does not create new fragment files" do
      schema = build_test_schema
      Dir.mktmpdir do |dir|
        GraphQL::Schema::CachedDump.dump(schema, cache_dir: dir)
        files_before = Dir.glob("#{dir}/types/*.sdl").map { |f| File.basename(f) }.sort
        fp_cache.clear
        GraphQL::Schema::CachedDump.dump(schema, cache_dir: dir)
        files_after = Dir.glob("#{dir}/types/*.sdl").map { |f| File.basename(f) }.sort
        assert_equal files_before, files_after
      end
    end
  end

  describe "Merkle root" do
    it "identical schemas produce the same Merkle root" do
      Dir.mktmpdir do |dir_a|
        Dir.mktmpdir do |dir_b|
          q_a = Class.new(GraphQL::Schema::Object) {
            graphql_name "Query"
            field :name, String, null: true
          }
          q_b = Class.new(GraphQL::Schema::Object) {
            graphql_name "Query"
            field :name, String, null: true
          }
          schema_a = Class.new(GraphQL::Schema) { query q_a }
          schema_b = Class.new(GraphQL::Schema) { query q_b }

          GraphQL::Schema::CachedDump.dump(schema_a, cache_dir: dir_a)
          fp_cache.clear
          GraphQL::Schema::CachedDump.dump(schema_b, cache_dir: dir_b)

          root_a = Dir.glob("#{dir_a}/schema_*.graphql").map { |f| File.basename(f) }.first
          root_b = Dir.glob("#{dir_b}/schema_*.graphql").map { |f| File.basename(f) }.first
          assert_equal root_a, root_b
        end
      end
    end

    it "different type names produce different Merkle roots" do
      Dir.mktmpdir do |dir_a|
        Dir.mktmpdir do |dir_b|
          q_a = Class.new(GraphQL::Schema::Object) {
            graphql_name "Query"
            field :name, String, null: true
          }
          q_b = Class.new(GraphQL::Schema::Object) {
            graphql_name "RootQuery"
            field :name, String, null: true
          }
          schema_a = Class.new(GraphQL::Schema) { query q_a }
          schema_b = Class.new(GraphQL::Schema) { query q_b }

          GraphQL::Schema::CachedDump.dump(schema_a, cache_dir: dir_a)
          fp_cache.clear
          GraphQL::Schema::CachedDump.dump(schema_b, cache_dir: dir_b)

          root_a = Dir.glob("#{dir_a}/schema_*.graphql").map { |f| File.basename(f) }.first
          root_b = Dir.glob("#{dir_b}/schema_*.graphql").map { |f| File.basename(f) }.first
          refute_equal root_a, root_b
        end
      end
    end
  end

  describe "FINGERPRINT_CACHE" do
    it "bounded to MAX_CACHE_ENTRIES" do
      schemas = 5.times.map do |i|
        q = Class.new(GraphQL::Schema::Object) {
          graphql_name "Query"
          field :"field_#{i}", String, null: true
        }
        Class.new(GraphQL::Schema) { query q }
      end

      Dir.mktmpdir do |dir|
        schemas.each_with_index do |s, i|
          GraphQL::Schema::CachedDump.dump(s, cache_dir: "#{dir}/#{i}")
        end
        max = GraphQL::Schema::CachedDump.send(:const_get, :MAX_CACHE_ENTRIES)
        assert fp_cache.size <= max, "Cache size #{fp_cache.size} exceeds MAX_CACHE_ENTRIES #{max}"
      end
    end
  end

  describe "incremental fingerprinting (watch_dirs)" do
    it "cold run produces correct output with watch_dirs" do
      schema = build_test_schema
      Dir.mktmpdir do |dir|
        watch_dir = File.join(dir, "src")
        FileUtils.mkdir_p(watch_dir)
        File.write(File.join(watch_dir, "types.rb"), "# schema source")
        cache_dir = File.join(dir, "cache")

        result = GraphQL::Schema::CachedDump.dump(schema, cache_dir: cache_dir, watch_dirs: [watch_dir])
        assert_equal schema.to_definition, result
      end
    end

    it "warm run uses fast path and returns correct output" do
      schema = build_test_schema
      Dir.mktmpdir do |dir|
        watch_dir = File.join(dir, "src")
        FileUtils.mkdir_p(watch_dir)
        File.write(File.join(watch_dir, "types.rb"), "# schema source")
        cache_dir = File.join(dir, "cache")

        GraphQL::Schema::CachedDump.dump(schema, cache_dir: cache_dir, watch_dirs: [watch_dir])
        fp_cache.clear
        result = GraphQL::Schema::CachedDump.dump(schema, cache_dir: cache_dir, watch_dirs: [watch_dir])
        assert_equal schema.to_definition, result
      end
    end

    it "modifying a watched file triggers incremental recomputation" do
      schema = build_test_schema
      Dir.mktmpdir do |dir|
        watch_dir = File.join(dir, "src")
        FileUtils.mkdir_p(watch_dir)
        File.write(File.join(watch_dir, "types.rb"), "# schema source")
        cache_dir = File.join(dir, "cache")

        GraphQL::Schema::CachedDump.dump(schema, cache_dir: cache_dir, watch_dirs: [watch_dir])
        fp_cache.clear

        File.write(File.join(watch_dir, "types.rb"), "# modified source")
        result = GraphQL::Schema::CachedDump.dump(schema, cache_dir: cache_dir, watch_dirs: [watch_dir])
        assert_equal schema.to_definition, result
      end
    end

    it "persists manifest and fingerprints files" do
      schema = build_test_schema
      Dir.mktmpdir do |dir|
        watch_dir = File.join(dir, "src")
        FileUtils.mkdir_p(watch_dir)
        File.write(File.join(watch_dir, "types.rb"), "# schema source")
        cache_dir = File.join(dir, "cache")

        GraphQL::Schema::CachedDump.dump(schema, cache_dir: cache_dir, watch_dirs: [watch_dir])

        assert File.exist?(File.join(cache_dir, "manifest.marshal"))
        assert File.exist?(File.join(cache_dir, "fingerprints.marshal"))
      end
    end

    it "handles corrupted marshal files gracefully" do
      schema = build_test_schema
      Dir.mktmpdir do |dir|
        watch_dir = File.join(dir, "src")
        FileUtils.mkdir_p(watch_dir)
        File.write(File.join(watch_dir, "types.rb"), "# schema source")
        cache_dir = File.join(dir, "cache")
        FileUtils.mkdir_p(File.join(cache_dir, "types"))

        File.binwrite(File.join(cache_dir, "manifest.marshal"), "corrupt \xFF\xFF")
        File.binwrite(File.join(cache_dir, "fingerprints.marshal"), "corrupt \xFF\xFF")

        result = GraphQL::Schema::CachedDump.dump(schema, cache_dir: cache_dir, watch_dirs: [watch_dir])
        assert_equal schema.to_definition, result
      end
    end
  end

  describe "safe_type_filename" do
    it "accepts valid GraphQL names" do
      valid_names = ["Query", "MyType_123", "_Private", "A"]
      valid_names.each do |name|
        assert_equal name, GraphQL::Schema::CachedDump.send(:safe_type_filename, name)
      end
    end

    it "rejects names with path traversal characters" do
      invalid_names = ["../etc/passwd", "foo/bar", "type name", "a\x00b", ""]
      invalid_names.each do |name|
        assert_raises(ArgumentError) do
          GraphQL::Schema::CachedDump.send(:safe_type_filename, name)
        end
      end
    end
  end

  describe "gc_stale_files" do
    it "removes stale fragment files after recomputation" do
      Dir.mktmpdir do |dir|
        q_v1 = Class.new(GraphQL::Schema::Object) {
          graphql_name "Query"
          field :name, String, null: true, description: "v1"
        }
        schema_v1 = Class.new(GraphQL::Schema) { query q_v1 }

        q_v2 = Class.new(GraphQL::Schema::Object) {
          graphql_name "Query"
          field :name, String, null: true, description: "v2"
        }
        schema_v2 = Class.new(GraphQL::Schema) { query q_v2 }

        watch_dir = File.join(dir, "src")
        FileUtils.mkdir_p(watch_dir)
        File.write(File.join(watch_dir, "query.rb"), "# v1")
        cache_dir = File.join(dir, "cache")

        GraphQL::Schema::CachedDump.dump(schema_v1, cache_dir: cache_dir, watch_dirs: [watch_dir])
        fp_cache.clear

        # Modify watched file to trigger GC
        File.write(File.join(watch_dir, "query.rb"), "# v2")
        GraphQL::Schema::CachedDump.dump(schema_v2, cache_dir: cache_dir, watch_dirs: [watch_dir])

        # Old fragment should be cleaned up
        fragments = Dir.glob("#{cache_dir}/types/Query_*.sdl")
        assert_equal 1, fragments.length
      end
    end

    it "removes old full schema files during GC" do
      Dir.mktmpdir do |dir|
        cache_dir = File.join(dir, "cache")
        FileUtils.mkdir_p(File.join(cache_dir, "types"))

        watch_dir = File.join(dir, "src")
        FileUtils.mkdir_p(watch_dir)
        File.write(File.join(watch_dir, "query.rb"), "# v0")

        q = Class.new(GraphQL::Schema::Object) {
          graphql_name "Query"
          field :field_0, String, null: true
        }
        schema = Class.new(GraphQL::Schema) { query q }

        fp_cache.clear
        GraphQL::Schema::CachedDump.dump(schema, cache_dir: cache_dir, watch_dirs: [watch_dir])

        # Manually create 5 old schema files to verify GC removes them
        5.times do |i|
          sleep 0.01
          File.write(File.join(cache_dir, "schema_#{'0' * 64}#{i}.graphql"), "old#{i}")
        end

        before_count = Dir.glob("#{cache_dir}/schema_*").length
        assert before_count > 2

        # Trigger a file change to invoke GC
        File.write(File.join(watch_dir, "query.rb"), "# v1")
        fp_cache.clear
        GraphQL::Schema::CachedDump.dump(schema, cache_dir: cache_dir, watch_dirs: [watch_dir])

        # GC runs before the new schema file is written, so it trims to 2,
        # then dump writes the new file (total 3 at most).
        after_count = Dir.glob("#{cache_dir}/schema_*").length
        assert after_count < before_count, "GC should have removed some schema files (before=#{before_count}, after=#{after_count})"
        assert after_count <= 3, "Expected at most 3 schema files after GC + new write, got #{after_count}"
      end
    end
  end

  describe "parallel execution" do
    def build_large_schema
      types = (1..25).map do |i|
        Class.new(GraphQL::Schema::Object) {
          graphql_name "Type#{i}"
          field :id, GraphQL::Types::ID, null: false
          field :name, String, null: true
        }
      end
      query_type = Class.new(GraphQL::Schema::Object) {
        graphql_name "Query"
        types.each_with_index { |t, i| field :"type#{i}", t, null: true }
      }
      Class.new(GraphQL::Schema) { query query_type }
    end

    it "parallel output matches serial output" do
      schema = build_large_schema
      Dir.mktmpdir do |dir|
        serial = GraphQL::Schema::CachedDump.dump(schema, cache_dir: "#{dir}/serial", parallel_workers: 1)
        fp_cache.clear
        parallel = GraphQL::Schema::CachedDump.dump(schema, cache_dir: "#{dir}/parallel", parallel_workers: 4)
        assert_equal serial, parallel
      end
    end

    it "parallel output matches to_definition" do
      schema = build_large_schema
      Dir.mktmpdir do |dir|
        result = GraphQL::Schema::CachedDump.dump(schema, cache_dir: dir, parallel_workers: 4)
        assert_equal schema.to_definition, result
      end
    end
  end

  describe "edge cases" do
    it "schema with non-standard root type names includes schema block" do
      Dir.mktmpdir do |dir|
        q = Class.new(GraphQL::Schema::Object) {
          graphql_name "MyQueryRoot"
          field :ping, String
        }
        schema = Class.new(GraphQL::Schema) { query q }

        result = GraphQL::Schema::CachedDump.dump(schema, cache_dir: dir)
        assert_equal schema.to_definition, result
        assert_includes result, "schema {"
        assert_includes result, "query: MyQueryRoot"
      end
    end

    it "schema with custom directive includes it in output" do
      Dir.mktmpdir do |dir|
        custom = Class.new(GraphQL::Schema::Directive) {
          graphql_name "rateLimit"
          description "Rate-limit a field"
          argument :max, GraphQL::Types::Int, required: true
          locations(GraphQL::Schema::Directive::FIELD_DEFINITION)
        }
        q = Class.new(GraphQL::Schema::Object) { graphql_name "Query"; field :x, String }
        schema = Class.new(GraphQL::Schema) { query q; directive custom }

        result = GraphQL::Schema::CachedDump.dump(schema, cache_dir: dir)
        assert_equal schema.to_definition, result
        assert_includes result, "directive @rateLimit"
      end
    end

    it "auto-creates cache directory if it does not exist" do
      Dir.mktmpdir do |base|
        new_dir = File.join(base, "deeply", "nested", "cache")
        refute File.directory?(new_dir)

        q = Class.new(GraphQL::Schema::Object) { graphql_name "Query"; field :x, String }
        schema = Class.new(GraphQL::Schema) { query q }

        GraphQL::Schema::CachedDump.dump(schema, cache_dir: new_dir)
        assert File.directory?(new_dir)
        assert_equal 1, Dir.glob("#{new_dir}/*.graphql").length
      end
    end

    it "schema with extra_types includes them" do
      Dir.mktmpdir do |dir|
        standalone = Class.new(GraphQL::Schema::Enum) {
          graphql_name "StandaloneEnum"
          value "ALPHA"
          value "BETA"
        }
        q = Class.new(GraphQL::Schema::Object) { graphql_name "Query"; field :x, String }
        schema = Class.new(GraphQL::Schema) { query q; extra_types standalone }

        result = GraphQL::Schema::CachedDump.dump(schema, cache_dir: dir)
        assert_equal schema.to_definition, result
        assert_includes result, "StandaloneEnum"
      end
    end
  end
end
