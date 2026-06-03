module Searchkick
  module Meilisearch
    # Concern mixed into Searchkick::Index. Provides zero-downtime full reindex
    # for Meilisearch.
    #
    # Elasticsearch/OpenSearch use an alias that points at a timestamped index
    # and is swapped atomically. Meilisearch has no aliases, so Searchkick
    # searches the concrete index named after the model. To rebuild without
    # downtime we:
    #
    #   1. build a fresh timestamped index and import into it
    #   2. atomically `swap_indexes` it with the live index (documents AND
    #      settings are exchanged in one operation)
    #   3. drop the now-stale temporary index
    #
    # On the first build (no live index yet) we import straight into the
    # concrete index - there is nothing to keep online.
    module Reindex
      def meilisearch_full_reindex(relation, import: true, resume: false, retain: false, mode: nil, refresh_interval: nil, scope: nil, wait: nil, job_options: nil)
        if resume
          raise Searchkick::Error, "resume is not supported for Meilisearch"
        end
        if mode && mode != :inline
          raise NotImplementedError, "Meilisearch reindex only supports mode: :inline (got #{mode.inspect})"
        end

        index_options = relation.searchkick_index_options
        import_options = {mode: :inline, full: true, scope: scope, job_options: job_options}

        if exists?
          # zero-downtime: build into a temp index, then atomically swap
          new_index = create_index(index_options: index_options)
          new_index.import_scope(relation, **import_options) if import

          Searchkick.client.swap_indexes(name, new_index.name)

          # the temp index now holds the old data
          Index.new(new_index.name, @options).delete unless retain
        else
          # first build: nothing live to protect, import directly
          create(index_options)
          import_scope(relation, **import_options) if import
        end

        true
      end
    end
  end
end
