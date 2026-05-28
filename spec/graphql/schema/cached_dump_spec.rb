# frozen_string_literal: true
require "graphql"
require "tmpdir"
require "rake"
require "graphql/rake_task"

RSpec.describe GraphQL::Schema::CachedDump do
  # Access the private constant via Module.const_get
  let(:fp_cache) { described_class.send(:const_get, :FINGERPRINT_CACHE) }

  before(:each) do
    fp_cache.clear
  end

  # ---------------------------------------------------------------------------
  # Shared test schema that exercises: objects, interfaces, enums, input objects,
  # unions, scalars, custom directives, deprecations, and default argument values.
  # ---------------------------------------------------------------------------
  let(:test_schema) do
    node_iface = Module.new do
      include GraphQL::Schema::Interface
      graphql_name "Node"
      field :id, GraphQL::Types::ID, null: false
    end

    status_enum = Class.new(GraphQL::Schema::Enum) do
      graphql_name "Status"
      description "Publication status"
      value "DRAFT"
      value "PUBLISHED"
      value "ARCHIVED", deprecation_reason: "Use PUBLISHED"
    end

    tag_input = Class.new(GraphQL::Schema::InputObject) do
      graphql_name "TagInput"
      description "Input for a tag"
      argument :name, String, required: true
      argument :color, String, required: false, default_value: "blue"
    end

    post_type = Class.new(GraphQL::Schema::Object) do
      graphql_name "Post"
      description "A blog post"
      implements node_iface
      field :id, GraphQL::Types::ID, null: false
      field :title, String, null: false
      field :body, String, null: true
      field :status, status_enum, null: false
      field :views, GraphQL::Types::Int, null: false, deprecation_reason: "Use analytics"
    end

    comment_type = Class.new(GraphQL::Schema::Object) do
      graphql_name "Comment"
      description "A comment"
      implements node_iface
      field :id, GraphQL::Types::ID, null: false
      field :text, String, null: false
    end

    content_union = Class.new(GraphQL::Schema::Union) do
      graphql_name "Content"
      description "Any piece of content"
      possible_types post_type, comment_type
    end

    url_scalar = Class.new(GraphQL::Schema::Scalar) do
      graphql_name "URL"
      specified_by_url "https://url.spec.whatwg.org/"
    end

    query_type = Class.new(GraphQL::Schema::Object) do
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
    end

    mutation_type = Class.new(GraphQL::Schema::Object) do
      graphql_name "Mutation"
      field :create_post, post_type do
        argument :title, String, required: true
        argument :tag, tag_input, required: false
      end
    end

    Class.new(GraphQL::Schema) do
      query query_type
      mutation mutation_type
      extra_types content_union
    end
  end

  # ---------------------------------------------------------------------------
  # 1. Core correctness
  # ---------------------------------------------------------------------------
  describe "dump (SDL)" do
    it "matches to_definition on first (cold) run" do
      Dir.mktmpdir do |dir|
        result = described_class.dump(test_schema, cache_dir: dir)
        expect(result).to eq(test_schema.to_definition)
      end
    end

    it "matches to_definition on second (warm, cache hit) run" do
      Dir.mktmpdir do |dir|
        described_class.dump(test_schema, cache_dir: dir)
        fp_cache.clear
        result = described_class.dump(test_schema, cache_dir: dir)
        expect(result).to eq(test_schema.to_definition)
      end
    end
  end

  describe "dump_json" do
    it "matches to_json on cold run" do
      Dir.mktmpdir do |dir|
        result = described_class.dump_json(test_schema, cache_dir: dir)
        expect(result).to eq(test_schema.to_json)
      end
    end

    it "matches to_json on warm run" do
      Dir.mktmpdir do |dir|
        described_class.dump_json(test_schema, cache_dir: dir)
        fp_cache.clear
        result = described_class.dump_json(test_schema, cache_dir: dir)
        expect(result).to eq(test_schema.to_json)
      end
    end
  end

  # ---------------------------------------------------------------------------
  # 2. Cache invalidation — fingerprint changes trigger re-render
  # ---------------------------------------------------------------------------
  describe "cache invalidation" do
    it "changing a field description changes the type fingerprint and produces updated SDL" do
      Dir.mktmpdir do |dir|
        q_v1 = Class.new(GraphQL::Schema::Object) do
          graphql_name "Query"
          field :name, String, null: true, description: "original description"
        end
        schema_v1 = Class.new(GraphQL::Schema) { query q_v1 }

        q_v2 = Class.new(GraphQL::Schema::Object) do
          graphql_name "Query"
          field :name, String, null: true, description: "updated description"
        end
        schema_v2 = Class.new(GraphQL::Schema) { query q_v2 }

        described_class.dump(schema_v1, cache_dir: dir)
        fp_cache.clear
        result_v2 = described_class.dump(schema_v2, cache_dir: dir)

        # Two distinct Query fragment files (one per fingerprint)
        query_sdl_files = Dir.glob("#{dir}/types/Query_*.sdl")
        expect(query_sdl_files.length).to eq(2)
        expect(result_v2).to include("updated description")
        expect(result_v2).not_to include("original description")
      end
    end

    it "changing a field nullability invalidates that type's fragment" do
      Dir.mktmpdir do |dir|
        q_v1 = Class.new(GraphQL::Schema::Object) do
          graphql_name "Query"
          field :name, String, null: true
        end
        schema_v1 = Class.new(GraphQL::Schema) { query q_v1 }

        q_v2 = Class.new(GraphQL::Schema::Object) do
          graphql_name "Query"
          field :name, String, null: false
        end
        schema_v2 = Class.new(GraphQL::Schema) { query q_v2 }

        described_class.dump(schema_v1, cache_dir: dir)
        fp_cache.clear
        result_v2 = described_class.dump(schema_v2, cache_dir: dir)

        expect(Dir.glob("#{dir}/types/Query_*.sdl").length).to eq(2)
        expect(result_v2).to include("name: String!")
      end
    end

    it "adding a field to an object type invalidates its fragment" do
      Dir.mktmpdir do |dir|
        post_v1 = Class.new(GraphQL::Schema::Object) do
          graphql_name "Post"
          field :title, String, null: false
        end
        q = Class.new(GraphQL::Schema::Object) do
          graphql_name "Query"
          field :post, post_v1
        end
        schema_v1 = Class.new(GraphQL::Schema) { query q }

        post_v2 = Class.new(GraphQL::Schema::Object) do
          graphql_name "Post"
          field :title, String, null: false
          field :body, String, null: true  # NEW
        end
        q2 = Class.new(GraphQL::Schema::Object) do
          graphql_name "Query"
          field :post, post_v2
        end
        schema_v2 = Class.new(GraphQL::Schema) { query q2 }

        described_class.dump(schema_v1, cache_dir: dir)
        fp_cache.clear
        result_v2 = described_class.dump(schema_v2, cache_dir: dir)

        expect(Dir.glob("#{dir}/types/Post_*.sdl").length).to eq(2)
        expect(result_v2).to include("body: String")
      end
    end

    it "changing an enum value invalidates the enum type's fragment" do
      Dir.mktmpdir do |dir|
        enum_v1 = Class.new(GraphQL::Schema::Enum) do
          graphql_name "Color"
          value "RED"
          value "BLUE"
        end
        q = Class.new(GraphQL::Schema::Object) do
          graphql_name "Query"
          field :color, enum_v1, null: true
        end
        schema_v1 = Class.new(GraphQL::Schema) { query q }

        enum_v2 = Class.new(GraphQL::Schema::Enum) do
          graphql_name "Color"
          value "RED"
          value "BLUE"
          value "GREEN"  # NEW VALUE
        end
        q2 = Class.new(GraphQL::Schema::Object) do
          graphql_name "Query"
          field :color, enum_v2, null: true
        end
        schema_v2 = Class.new(GraphQL::Schema) { query q2 }

        described_class.dump(schema_v1, cache_dir: dir)
        fp_cache.clear
        result_v2 = described_class.dump(schema_v2, cache_dir: dir)

        expect(Dir.glob("#{dir}/types/Color_*.sdl").length).to eq(2)
        expect(result_v2).to include("GREEN")
      end
    end

    it "changing an input object argument type invalidates its fragment" do
      Dir.mktmpdir do |dir|
        input_v1 = Class.new(GraphQL::Schema::InputObject) do
          graphql_name "PostInput"
          argument :title, String, required: true
        end
        q = Class.new(GraphQL::Schema::Object) do
          graphql_name "Query"
          field :search, String, null: true do
            argument :input, input_v1, required: false
          end
        end
        schema_v1 = Class.new(GraphQL::Schema) { query q }

        input_v2 = Class.new(GraphQL::Schema::InputObject) do
          graphql_name "PostInput"
          argument :title, String, required: true
          argument :limit, GraphQL::Types::Int, required: false, default_value: 5  # NEW
        end
        q2 = Class.new(GraphQL::Schema::Object) do
          graphql_name "Query"
          field :search, String, null: true do
            argument :input, input_v2, required: false
          end
        end
        schema_v2 = Class.new(GraphQL::Schema) { query q2 }

        described_class.dump(schema_v1, cache_dir: dir)
        fp_cache.clear
        result_v2 = described_class.dump(schema_v2, cache_dir: dir)

        expect(Dir.glob("#{dir}/types/PostInput_*.sdl").length).to eq(2)
        expect(result_v2).to include("limit: Int = 5")
      end
    end

    it "adding a type-level directive invalidates that type's fragment" do
      Dir.mktmpdir do |dir|
        custom_dir = Class.new(GraphQL::Schema::Directive) do
          graphql_name "someDirective"
          locations(GraphQL::Schema::Directive::OBJECT)
        end

        q_v1 = Class.new(GraphQL::Schema::Object) do
          graphql_name "Query"
          field :name, String, null: true
        end
        schema_v1 = Class.new(GraphQL::Schema) { query q_v1; directive custom_dir }

        q_v2 = Class.new(GraphQL::Schema::Object) do
          graphql_name "Query"
          directive custom_dir  # Apply the directive to this type
          field :name, String, null: true
        end
        schema_v2 = Class.new(GraphQL::Schema) { query q_v2; directive custom_dir }

        described_class.dump(schema_v1, cache_dir: dir)
        fp_cache.clear
        result_v2 = described_class.dump(schema_v2, cache_dir: dir)

        expect(Dir.glob("#{dir}/types/Query_*.sdl").length).to eq(2)
        expect(result_v2).to include("@someDirective")
      end
    end

    it "changing interface membership invalidates the object's fragment" do
      Dir.mktmpdir do |dir|
        iface = Module.new do
          include GraphQL::Schema::Interface
          graphql_name "Identifiable"
          field :id, GraphQL::Types::ID, null: false
        end

        post_v1 = Class.new(GraphQL::Schema::Object) do
          graphql_name "Post"
          field :id, GraphQL::Types::ID, null: false
          field :title, String, null: false
        end
        q = Class.new(GraphQL::Schema::Object) do
          graphql_name "Query"
          field :post, post_v1
        end
        schema_v1 = Class.new(GraphQL::Schema) { query q }

        post_v2 = Class.new(GraphQL::Schema::Object) do
          graphql_name "Post"
          implements iface  # NOW IMPLEMENTS INTERFACE
          field :id, GraphQL::Types::ID, null: false
          field :title, String, null: false
        end
        q2 = Class.new(GraphQL::Schema::Object) do
          graphql_name "Query"
          field :post, post_v2
        end
        schema_v2 = Class.new(GraphQL::Schema) { query q2 }

        described_class.dump(schema_v1, cache_dir: dir)
        fp_cache.clear
        result_v2 = described_class.dump(schema_v2, cache_dir: dir)

        expect(Dir.glob("#{dir}/types/Post_*.sdl").length).to eq(2)
        expect(result_v2).to include("Post implements Identifiable")
      end
    end

    it "changing a union member set invalidates the union's fragment" do
      Dir.mktmpdir do |dir|
        type_a = Class.new(GraphQL::Schema::Object) do
          graphql_name "TypeA"
          field :id, GraphQL::Types::ID, null: false
        end
        type_b = Class.new(GraphQL::Schema::Object) do
          graphql_name "TypeB"
          field :id, GraphQL::Types::ID, null: false
        end
        type_c = Class.new(GraphQL::Schema::Object) do
          graphql_name "TypeC"
          field :id, GraphQL::Types::ID, null: false
        end

        union_v1 = Class.new(GraphQL::Schema::Union) do
          graphql_name "MyUnion"
          possible_types type_a, type_b
        end
        q = Class.new(GraphQL::Schema::Object) do
          graphql_name "Query"
          field :thing, union_v1, null: true
        end
        schema_v1 = Class.new(GraphQL::Schema) { query q }

        union_v2 = Class.new(GraphQL::Schema::Union) do
          graphql_name "MyUnion"
          possible_types type_a, type_b, type_c  # NEW MEMBER
        end
        q2 = Class.new(GraphQL::Schema::Object) do
          graphql_name "Query"
          field :thing, union_v2, null: true
        end
        schema_v2 = Class.new(GraphQL::Schema) { query q2 }

        described_class.dump(schema_v1, cache_dir: dir)
        fp_cache.clear
        result_v2 = described_class.dump(schema_v2, cache_dir: dir)

        expect(Dir.glob("#{dir}/types/MyUnion_*.sdl").length).to eq(2)
        expect(result_v2).to include("TypeC")
      end
    end
  end

  # ---------------------------------------------------------------------------
  # 3. Cache structure
  # ---------------------------------------------------------------------------
  describe "cache structure" do
    it "cold run creates types/<TypeName>_<fingerprint>.sdl fragment files" do
      Dir.mktmpdir do |dir|
        described_class.dump(test_schema, cache_dir: dir)

        sdl_files = Dir.glob("#{dir}/types/*.sdl")
        expect(sdl_files).not_to be_empty

        sdl_files.each do |path|
          name = File.basename(path)
          expect(name).to match(/\A[A-Za-z][A-Za-z0-9]*_[0-9a-f]{64}\.sdl\z/)
        end
      end
    end

    it "cold run creates schema_<merkle_root>.graphql full cache file" do
      Dir.mktmpdir do |dir|
        described_class.dump(test_schema, cache_dir: dir)

        full_files = Dir.glob("#{dir}/schema_*.graphql")
        expect(full_files.length).to eq(1)
        expect(File.basename(full_files.first)).to match(/\Aschema_[0-9a-f]{64}\.graphql\z/)
      end
    end

    it "warm run (nothing changed) does NOT create new fragment files" do
      Dir.mktmpdir do |dir|
        described_class.dump(test_schema, cache_dir: dir)
        files_before = Dir.glob("#{dir}/types/*.sdl").map { |f| File.basename(f) }.sort

        fp_cache.clear  # Simulate new process — fragments remain on disk

        described_class.dump(test_schema, cache_dir: dir)
        files_after = Dir.glob("#{dir}/types/*.sdl").map { |f| File.basename(f) }.sort

        expect(files_after).to eq(files_before)
      end
    end

    it "partial change: only the modified type gets a new fragment; others are reused" do
      Dir.mktmpdir do |dir|
        # Use the same Query class in both schema versions so its fingerprint is identical.
        # Only the Post extra_type changes between v1 and v2.
        shared_query = Class.new(GraphQL::Schema::Object) do
          graphql_name "Query"
          field :name, String, null: true
        end

        post_v1 = Class.new(GraphQL::Schema::Object) do
          graphql_name "Post"
          field :title, String, null: false
        end

        post_v2 = Class.new(GraphQL::Schema::Object) do
          graphql_name "Post"
          field :title, String, null: false
          field :body, String, null: true  # added field
        end

        schema_v1 = Class.new(GraphQL::Schema) { query shared_query; extra_types post_v1 }
        schema_v2 = Class.new(GraphQL::Schema) { query shared_query; extra_types post_v2 }

        described_class.dump(schema_v1, cache_dir: dir)
        query_files_v1 = Dir.glob("#{dir}/types/Query_*.sdl").map { |f| File.basename(f) }

        fp_cache.clear
        described_class.dump(schema_v2, cache_dir: dir)
        query_files_all = Dir.glob("#{dir}/types/Query_*.sdl").map { |f| File.basename(f) }
        post_files_all  = Dir.glob("#{dir}/types/Post_*.sdl").map  { |f| File.basename(f) }

        # Query type is the same Ruby class — fingerprint is identical, no new file
        expect(query_files_all).to eq(query_files_v1)

        # Post type changed — two distinct fragment files (v1 + v2)
        expect(post_files_all.length).to eq(2)
      end
    end

    it "dump_json creates schema_<merkle_root>_<options_key>.json cache file" do
      Dir.mktmpdir do |dir|
        described_class.dump_json(test_schema, cache_dir: dir)

        json_files = Dir.glob("#{dir}/schema_*.json")
        expect(json_files.length).to eq(1)
        expect(File.basename(json_files.first)).to match(
          /\Aschema_[0-9a-f]{64}_[0-9a-f]{64}\.json\z/
        )
      end
    end

    it "different json_options produce different cache files" do
      Dir.mktmpdir do |dir|
        described_class.dump_json(test_schema, cache_dir: dir)
        described_class.dump_json(test_schema, cache_dir: dir, include_is_one_of: true)
        described_class.dump_json(test_schema, cache_dir: dir, include_is_repeatable: true)

        json_files = Dir.glob("#{dir}/schema_*.json")
        expect(json_files.length).to eq(3)
      end
    end
  end

  # ---------------------------------------------------------------------------
  # 4. Merkle root correctness
  # ---------------------------------------------------------------------------
  describe "Merkle root" do
    it "two schemas with identical type definitions produce the same Merkle root" do
      Dir.mktmpdir do |dir_a|
        Dir.mktmpdir do |dir_b|
          q_a = Class.new(GraphQL::Schema::Object) do
            graphql_name "Query"
            field :name, String, null: true
          end
          q_b = Class.new(GraphQL::Schema::Object) do
            graphql_name "Query"
            field :name, String, null: true
          end
          schema_a = Class.new(GraphQL::Schema) { query q_a }
          schema_b = Class.new(GraphQL::Schema) { query q_b }

          described_class.dump(schema_a, cache_dir: dir_a)
          fp_cache.clear
          described_class.dump(schema_b, cache_dir: dir_b)

          root_a = Dir.glob("#{dir_a}/schema_*.graphql").map { |f| File.basename(f) }.first
          root_b = Dir.glob("#{dir_b}/schema_*.graphql").map { |f| File.basename(f) }.first

          expect(root_a).to eq(root_b)
        end
      end
    end

    it "a type name change produces a different Merkle root" do
      Dir.mktmpdir do |dir_a|
        Dir.mktmpdir do |dir_b|
          q_a = Class.new(GraphQL::Schema::Object) do
            graphql_name "Query"
            field :name, String, null: true
          end
          q_b = Class.new(GraphQL::Schema::Object) do
            graphql_name "RootQuery"  # different graphql_name
            field :name, String, null: true
          end
          schema_a = Class.new(GraphQL::Schema) { query q_a }
          schema_b = Class.new(GraphQL::Schema) { query q_b }

          described_class.dump(schema_a, cache_dir: dir_a)
          fp_cache.clear
          described_class.dump(schema_b, cache_dir: dir_b)

          root_a = Dir.glob("#{dir_a}/schema_*.graphql").map { |f| File.basename(f) }.first
          root_b = Dir.glob("#{dir_b}/schema_*.graphql").map { |f| File.basename(f) }.first

          expect(root_a).not_to eq(root_b)
        end
      end
    end
  end

  # ---------------------------------------------------------------------------
  # 5. FINGERPRINT_CACHE memoization
  # ---------------------------------------------------------------------------
  describe "FINGERPRINT_CACHE memoization" do
    it "calling dump twice on the same schema object uses memoized fingerprints" do
      Dir.mktmpdir do |dir|
        described_class.dump(test_schema, cache_dir: dir)
        expect(fp_cache.size).to eq(1)
        expect(fp_cache).to have_key(test_schema)

        first_fingerprints = fp_cache[test_schema]

        described_class.dump(test_schema, cache_dir: dir)
        expect(fp_cache.size).to eq(1)
        expect(fp_cache[test_schema]).to equal(first_fingerprints)  # same object_id
      end
    end

    it "different schema objects have independent cache entries" do
      Dir.mktmpdir do |dir|
        q1 = Class.new(GraphQL::Schema::Object) { graphql_name "Query"; field :a, String }
        q2 = Class.new(GraphQL::Schema::Object) { graphql_name "Query"; field :a, String }
        schema1 = Class.new(GraphQL::Schema) { query q1 }
        schema2 = Class.new(GraphQL::Schema) { query q2 }

        described_class.dump(schema1, cache_dir: dir)
        described_class.dump(schema2, cache_dir: dir)

        expect(fp_cache.size).to eq(2)
        expect(fp_cache).to have_key(schema1)
        expect(fp_cache).to have_key(schema2)
      end
    end
  end

  # ---------------------------------------------------------------------------
  # 6. Edge cases
  # ---------------------------------------------------------------------------
  describe "edge cases" do
    it "schema with extra_types includes those types in dump and Merkle root" do
      Dir.mktmpdir do |dir|
        standalone_enum = Class.new(GraphQL::Schema::Enum) do
          graphql_name "StandaloneEnum"
          value "ALPHA"
          value "BETA"
        end

        q = Class.new(GraphQL::Schema::Object) { graphql_name "Query"; field :x, String }
        schema = Class.new(GraphQL::Schema) { query q; extra_types standalone_enum }

        result = described_class.dump(schema, cache_dir: dir)

        expect(result).to eq(schema.to_definition)
        expect(result).to include("StandaloneEnum")

        # Merkle root must include the extra type
        files_with = Dir.glob("#{dir}/schema_*.graphql").map { |f| File.basename(f) }

        # Schema without extra_type has a different Merkle root
        fp_cache.clear
        Dir.mktmpdir do |dir2|
          schema_without = Class.new(GraphQL::Schema) { query q }
          described_class.dump(schema_without, cache_dir: dir2)
          files_without = Dir.glob("#{dir2}/schema_*.graphql").map { |f| File.basename(f) }
          expect(files_with.first).not_to eq(files_without.first)
        end
      end
    end

    it "schema with non-standard root type names includes schema block in output" do
      Dir.mktmpdir do |dir|
        q = Class.new(GraphQL::Schema::Object) do
          graphql_name "MyQueryRoot"
          field :ping, String
        end
        schema = Class.new(GraphQL::Schema) { query q }

        result = described_class.dump(schema, cache_dir: dir)

        expect(result).to eq(schema.to_definition)
        expect(result).to include("schema {")
        expect(result).to include("query: MyQueryRoot")
      end
    end

    it "schema with a custom non-built-in directive definition includes the directive in output" do
      Dir.mktmpdir do |dir|
        custom = Class.new(GraphQL::Schema::Directive) do
          graphql_name "rateLimit"
          description "Rate-limit a field"
          argument :max, GraphQL::Types::Int, required: true
          locations(GraphQL::Schema::Directive::FIELD_DEFINITION)
        end

        q = Class.new(GraphQL::Schema::Object) { graphql_name "Query"; field :x, String }
        schema = Class.new(GraphQL::Schema) { query q; directive custom }

        result = described_class.dump(schema, cache_dir: dir)

        expect(result).to eq(schema.to_definition)
        expect(result).to include("directive @rateLimit")
      end
    end

    it "schema with an interface that implements another interface includes the membership in fingerprint" do
      Dir.mktmpdir do |dir|
        parent_iface = Module.new do
          include GraphQL::Schema::Interface
          graphql_name "Node"
          field :id, GraphQL::Types::ID, null: false
        end

        # v1: Resource interface does NOT implement Node
        child_iface_v1 = Module.new do
          include GraphQL::Schema::Interface
          graphql_name "Resource"
          field :url, String, null: false
        end

        concrete_v1 = Class.new(GraphQL::Schema::Object) do
          graphql_name "Post"
          implements child_iface_v1
          field :url, String, null: false
        end

        q = Class.new(GraphQL::Schema::Object) do
          graphql_name "Query"
          field :resource, child_iface_v1, null: true
        end
        schema_v1 = Class.new(GraphQL::Schema) { query q; orphan_types [concrete_v1] }

        # v2: Resource interface NOW implements Node
        child_iface_v2 = Module.new do
          include GraphQL::Schema::Interface
          graphql_name "Resource"
          implements parent_iface
          field :id, GraphQL::Types::ID, null: false
          field :url, String, null: false
        end

        concrete_v2 = Class.new(GraphQL::Schema::Object) do
          graphql_name "Post"
          implements child_iface_v2
          field :id, GraphQL::Types::ID, null: false
          field :url, String, null: false
        end

        q2 = Class.new(GraphQL::Schema::Object) do
          graphql_name "Query"
          field :resource, child_iface_v2, null: true
        end
        schema_v2 = Class.new(GraphQL::Schema) { query q2; orphan_types [concrete_v2] }

        described_class.dump(schema_v1, cache_dir: dir)
        fp_cache.clear
        result_v2 = described_class.dump(schema_v2, cache_dir: dir)

        # Two distinct Resource fragment files — fingerprint changed when interface membership was added
        expect(Dir.glob("#{dir}/types/Resource_*.sdl").length).to eq(2)
        expect(result_v2).to include("Resource implements Node")
      end
    end

    it "schema with no mutation or subscription dumps correctly" do
      Dir.mktmpdir do |dir|
        q = Class.new(GraphQL::Schema::Object) do
          graphql_name "Query"
          field :name, String, null: true
        end
        schema = Class.new(GraphQL::Schema) { query q }

        result = described_class.dump(schema, cache_dir: dir)

        expect(result).to eq(schema.to_definition)
        expect(result).not_to include("mutation")
        expect(result).not_to include("subscription")
      end
    end

    it "automatically creates the cache dir if it does not exist" do
      base = Dir.mktmpdir
      new_dir = File.join(base, "deeply", "nested", "graphql")
      begin
        expect(File.directory?(new_dir)).to be(false)

        q = Class.new(GraphQL::Schema::Object) { graphql_name "Query"; field :x, String }
        schema = Class.new(GraphQL::Schema) { query q }

        described_class.dump(schema, cache_dir: new_dir)

        expect(File.directory?(new_dir)).to be(true)
        expect(Dir.glob("#{new_dir}/*.graphql").length).to eq(1)
      ensure
        FileUtils.rm_rf(base)
      end
    end
  end

  # ---------------------------------------------------------------------------
  # 7. RakeTask integration
  # ---------------------------------------------------------------------------
  describe "GraphQL::RakeTask integration" do
    let(:rake_schema) do
      q = Class.new(GraphQL::Schema::Object) do
        graphql_name "Query"
        field :hello, String, null: true
      end
      Class.new(GraphQL::Schema) { query q }
    end

    it "with cache_dir set, calls CachedDump.dump for IDL" do
      Dir.mktmpdir do |cache_dir|
        Dir.mktmpdir do |out_dir|
          allow(GraphQL::Schema::CachedDump).to receive(:dump).and_call_original

          ns = "rake_cached_idl_#{rand(99999)}"
          task_obj = GraphQL::RakeTask.new(
            namespace: ns,
            cache_dir: cache_dir,
            idl_outfile: File.join(out_dir, "schema.graphql"),
            json_outfile: File.join(out_dir, "schema.json")
          ) do |t|
            t.load_schema = ->(_task) { rake_schema }
          end

          fp_cache.clear
          task_obj.send(:write_outfile, :to_definition, File.join(out_dir, "schema.graphql"))

          expect(GraphQL::Schema::CachedDump).to have_received(:dump)

          content = File.read(File.join(out_dir, "schema.graphql"))
          expect(content.strip).to eq(rake_schema.to_definition.strip)
        end
      end
    end

    it "with cache_dir set, calls CachedDump.dump_json for JSON" do
      Dir.mktmpdir do |cache_dir|
        Dir.mktmpdir do |out_dir|
          allow(GraphQL::Schema::CachedDump).to receive(:dump_json).and_call_original

          ns = "rake_cached_json_#{rand(99999)}"
          task_obj = GraphQL::RakeTask.new(
            namespace: ns,
            cache_dir: cache_dir,
            idl_outfile: File.join(out_dir, "schema.graphql"),
            json_outfile: File.join(out_dir, "schema.json")
          ) do |t|
            t.load_schema = ->(_task) { rake_schema }
          end

          fp_cache.clear
          task_obj.send(:write_outfile, :to_json, File.join(out_dir, "schema.json"))

          expect(GraphQL::Schema::CachedDump).to have_received(:dump_json)

          content = File.read(File.join(out_dir, "schema.json"))
          expect(JSON.parse(content)).to eq(JSON.parse(rake_schema.to_json))
        end
      end
    end

    it "without cache_dir uses standard to_definition / to_json (no CachedDump call)" do
      Dir.mktmpdir do |out_dir|
        allow(GraphQL::Schema::CachedDump).to receive(:dump).and_call_original
        allow(GraphQL::Schema::CachedDump).to receive(:dump_json).and_call_original

        ns = "rake_uncached_#{rand(99999)}"
        task_obj = GraphQL::RakeTask.new(
          namespace: ns,
          idl_outfile: File.join(out_dir, "schema.graphql"),
          json_outfile: File.join(out_dir, "schema.json")
        ) do |t|
          t.load_schema = ->(_task) { rake_schema }
          # Note: no cache_dir set
        end

        task_obj.send(:write_outfile, :to_definition, File.join(out_dir, "schema.graphql"))
        task_obj.send(:write_outfile, :to_json, File.join(out_dir, "schema.json"))

        expect(GraphQL::Schema::CachedDump).not_to have_received(:dump)
        expect(GraphQL::Schema::CachedDump).not_to have_received(:dump_json)

        idl_content = File.read(File.join(out_dir, "schema.graphql"))
        expect(idl_content.strip).to eq(rake_schema.to_definition.strip)
      end
    end
  end

  # ---------------------------------------------------------------------------
  # 8. Parallel execution
  # ---------------------------------------------------------------------------
  let(:large_schema) do
    types = (1..25).map do |i|
      Class.new(GraphQL::Schema::Object) do
        graphql_name "Type#{i}"
        field :id, GraphQL::Types::ID, null: false
        field :name, String, null: true
      end
    end
    query_type = Class.new(GraphQL::Schema::Object) do
      graphql_name "Query"
      types.each_with_index do |t, i|
        field :"type#{i}", t, null: true
      end
    end
    Class.new(GraphQL::Schema) { query query_type }
  end

  describe "parallel execution" do
    it "parallel dump output matches serial dump output" do
      Dir.mktmpdir do |dir|
        serial = described_class.dump(large_schema, cache_dir: dir, parallel_workers: 1)
        fp_cache.clear
        FileUtils.rm_rf(dir); FileUtils.mkdir_p(dir)
        parallel = described_class.dump(large_schema, cache_dir: dir, parallel_workers: 4)
        expect(parallel).to eq(serial)
      end
    end

    it "parallel dump_json output matches serial dump_json output" do
      Dir.mktmpdir do |dir|
        serial = described_class.dump_json(large_schema, cache_dir: dir, parallel_workers: 1)
        fp_cache.clear
        parallel = described_class.dump_json(large_schema, cache_dir: dir, parallel_workers: 4)
        expect(JSON.parse(parallel)).to eq(JSON.parse(serial))
      end
    end

    it "parallel dump matches to_definition" do
      Dir.mktmpdir do |dir|
        result = described_class.dump(large_schema, cache_dir: dir, parallel_workers: 4)
        expect(result).to eq(large_schema.to_definition)
      end
    end

    it "parallel warm run (full cache hit) still returns correct output" do
      Dir.mktmpdir do |dir|
        described_class.dump(large_schema, cache_dir: dir, parallel_workers: 4)
        fp_cache.clear
        result = described_class.dump(large_schema, cache_dir: dir, parallel_workers: 4)
        expect(result).to eq(large_schema.to_definition)
      end
    end

    it "all fragment files are created with parallel workers" do
      Dir.mktmpdir do |dir|
        described_class.dump(large_schema, cache_dir: dir, parallel_workers: 4)
        sdl_files = Dir.glob("#{dir}/types/*.sdl")
        expect(sdl_files.length).to be >= 25
      end
    end
  end

  describe "Schema::Printer parallel output" do
    it "parallel_workers output matches serial output" do
      serial = large_schema.to_definition(parallel_workers: 1)
      parallel = large_schema.to_definition(parallel_workers: 4)
      expect(parallel).to eq(serial)
    end
  end
end
