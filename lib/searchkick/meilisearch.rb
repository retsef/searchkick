# Meilisearch backend adapter for Searchkick.
#
# Strategy: present an Elasticsearch/OpenSearch *client-shaped* facade so the
# rest of Searchkick (Query, Results, Index, Indexer) keeps calling the same
# methods (`search`, `msearch`, `bulk`, `get`, `indices.*`, `info`) it already
# uses for ES. All Meilisearch-specific translation lives here:
#
#   * request:  Searchkick's generated ES query body  ->  Meilisearch search params
#   * response: Meilisearch response                   ->  ES-shaped response hash
#
# Where a Searchkick/ES feature has NO faithful Meilisearch equivalent, this
# adapter raises explicitly (Searchkick::InvalidQueryError or NotImplementedError)
# rather than returning silently-wrong results. See UNSUPPORTED notes inline.
#
# requires the `meilisearch` gem
module Searchkick
  module Meilisearch
    # primary key field injected into every document so Meilisearch has a
    # stable, filterable/sortable id (ES keeps `_id` out of `_source`)
    PRIMARY_KEY = "id".freeze

    # Wraps ::Meilisearch::Client and mimics the subset of the ES client
    # interface that Searchkick relies on.
    class Client
      attr_reader :ms

      def initialize(url: nil, api_key: nil, options: {})
        require "meilisearch"

        url ||= ENV["MEILISEARCH_URL"] || "http://localhost:7700"
        api_key ||= ENV["MEILISEARCH_API_KEY"]
        @ms = ::Meilisearch::Client.new(url, api_key, **options)
      end

      # --- server info -------------------------------------------------------

      # shaped like ES `client.info` so Searchkick.server_info / server_version
      # keep working. distribution "meilisearch" lets Searchkick branch.
      def info
        version = @ms.version
        {
          "version" => {
            "number" => version["pkgVersion"],
            "distribution" => "meilisearch"
          }
        }
      end

      # --- search ------------------------------------------------------------

      def search(params)
        Searchkick::Meilisearch::Search.new(self, params).execute
      end

      def msearch(params)
        Searchkick::Meilisearch::MultiSearch.new(self, params).execute
      end

      # --- documents ---------------------------------------------------------

      # translate ES bulk action lines into Meilisearch add/delete document
      # calls, then wait for the async tasks so callers observe ES-like sync
      # semantics. returns an ES-shaped bulk response.
      def bulk(body:)
        Searchkick::Meilisearch::Bulk.new(self, body).execute
      end

      # ES `client.get(index:, id:, ...)` -> Meilisearch get_one_document
      def get(opts)
        index_uid = opts[:index]
        id = opts[:id]
        document = index(index_uid).document(id)
        {"_source" => document}
      rescue ::Meilisearch::ApiError => e
        raise translate_error(e)
      end

      # --- unsupported transport features -----------------------------------

      def scroll(*)
        raise NotImplementedError, "Meilisearch does not support the scroll API"
      end

      def clear_scroll(*)
        raise NotImplementedError, "Meilisearch does not support the scroll API"
      end

      # --- index management facade ------------------------------------------

      def indices
        @indices ||= Searchkick::Meilisearch::Indices.new(self)
      end

      # raw index handle helper used by the facade/search/bulk
      def index(uid)
        @ms.index(uid)
      end

      def wait_for_task(task)
        # ::Meilisearch returns a Models::Task or a Hash with "taskUid"
        uid = task.respond_to?(:task_uid) ? task.task_uid : (task["taskUid"] || task["uid"])
        @ms.wait_for_task(uid)
      end

      def translate_error(e)
        Searchkick::Meilisearch.translate_error(e)
      end
    end

    # Index management facade. Mirrors `client.indices.*`.
    #
    # NOTE: Meilisearch has no analyzers/tokenizers/mappings and (historically)
    # no aliases. Searchkick's analysis settings are silently dropped here -
    # Meilisearch handles tokenization/typo-tolerance/prefix-search internally.
    class Indices
      def initialize(client)
        @client = client
        @ms = client.ms
      end

      # body is the ES {settings:, mappings:} blob from IndexOptions - ignored.
      # We create a Meilisearch index with our injected primary key.
      def create(index:, body: {})
        task = @ms.create_index(index, primary_key: Searchkick::Meilisearch::PRIMARY_KEY)
        @client.wait_for_task(task)
        {"acknowledged" => true}
      rescue ::Meilisearch::ApiError => e
        raise @client.translate_error(e)
      end

      def delete(index:)
        Array(index).each do |uid|
          task = @ms.delete_index(uid)
          @client.wait_for_task(task)
        end
        {"acknowledged" => true}
      rescue ::Meilisearch::ApiError => e
        raise @client.translate_error(e)
      end

      def exists(index:)
        @ms.index(index).fetch_info
        true
      rescue ::Meilisearch::ApiError => e
        return false if e.http_code == 404
        raise @client.translate_error(e)
      end

      # Meilisearch is near-real-time via its task queue; no manual refresh.
      def refresh(index:)
        {"acknowledged" => true}
      end

      # Meilisearch has no aliases. Searchkick treats a missing alias as "index
      # name is a concrete index", which is exactly what we want here.
      def exists_alias(name:)
        false
      end

      def get_alias(*)
        # no aliases -> behave like ES "not found" so callers treat the index
        # name as fresh/concrete
        raise Searchkick::Meilisearch::NotFoundError, "aliases not supported"
      end
      alias_method :get_aliases, :get_alias

      def update_aliases(*)
        # zero-downtime alias swapping maps to Meilisearch `swap_indexes`, which
        # requires changes to Searchkick::Index. Out of scope for this adapter.
        raise NotImplementedError,
          "alias-based reindexing is not supported - Meilisearch uses swap_indexes"
      end

      def get_mapping(index:)
        {index => {"mappings" => {}}}
      end

      def get_settings(index:)
        settings = @ms.index(index).settings
        {index => {"settings" => {"index" => settings}}}
      rescue ::Meilisearch::ApiError => e
        raise @client.translate_error(e)
      end

      def put_settings(index:, body:)
        raise NotImplementedError, "settings translation not implemented"
      end

      def analyze(*)
        raise NotImplementedError, "Meilisearch does not expose an analyze API"
      end
    end

    class NotFoundError < Searchkick::Error; end

    def self.translate_error(e)
      if e.respond_to?(:http_code) && e.http_code == 404
        NotFoundError.new(e.message)
      else
        Searchkick::InvalidQueryError.new(e.message)
      end
    end
  end
end

require_relative "meilisearch/search"
require_relative "meilisearch/bulk"
