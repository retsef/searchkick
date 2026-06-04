require_relative "stemmer"

module Searchkick
  module Meilisearch
    # Concern mixed into Searchkick::IndexOptions. Produces Meilisearch index
    # settings (instead of the Elasticsearch analysis/mappings blob) from the
    # searchkick model options.
    #
    # Meilisearch has no analyzers/tokenizers/mappings - tokenization, typo
    # tolerance, and prefix search are handled internally. Only a flat set of
    # index settings is configurable, so anything that relies on ES-specific
    # analysis raises explicitly here.
    #
    # Keys are emitted in Meilisearch's camelCase form so the adapter can pass
    # them straight to `update_settings`.
    module IndexOptions
      def meilisearch_index_options
        reject_unsupported_meilisearch_options!

        settings = {
          "searchableAttributes" => meilisearch_searchable,
          "filterableAttributes" => meilisearch_filterable,
          "sortableAttributes" => meilisearch_sortable,
          "pagination" => {"maxTotalHits" => meilisearch_max_total_hits}
        }

        synonyms = meilisearch_synonyms
        settings["synonyms"] = synonyms if synonyms.any?

        embedders = meilisearch_embedders
        settings["embedders"] = embedders if embedders.any?

        {
          meilisearch: {
            primary_key: Searchkick::Meilisearch::PRIMARY_KEY,
            settings: settings
          }
        }
      end

      # knn fields -> Meilisearch userProvided embedders (vector search)
      def meilisearch_embedders
        (options[:knn] || {}).each_with_object({}) do |(field, field_options), embedders|
          field_options ||= {}
          distance = field_options[:distance]
          if distance && distance.to_s != "cosine"
            raise ArgumentError, "Meilisearch vector search only supports cosine distance (got #{distance.inspect})"
          end

          embedders[field.to_s] = {
            "source" => "userProvided",
            "dimensions" => field_options[:dimensions]
          }
        end
      end

      private

      # model options that depend on ES-only analysis/features and have no
      # faithful Meilisearch equivalent
      # NOTE: `language` is supported via external stemming (ruby-stemmer);
      # `knn` is supported via Meilisearch vector search (embedders).
      MEILISEARCH_UNSUPPORTED_OPTIONS = [
        :conversions, :conversions_v2, :geo_shape, :locations,
        :text_start, :text_middle, :text_end,
        :word_start, :word_middle, :word_end,
        :stemmer, :stemmer_override, :stem_exclusion,
        :suggest, :similarity, :search_synonyms, :special_characters
      ].freeze

      def reject_unsupported_meilisearch_options!
        present = MEILISEARCH_UNSUPPORTED_OPTIONS.select { |k| options[k] }
        if present.any?
          raise ArgumentError,
            "Meilisearch does not support these searchkick options: #{present.join(", ")}"
        end

        if options[:case_sensitive]
          raise ArgumentError, "Meilisearch does not support case_sensitive"
        end

        if options[:match] && options[:match] != :word
          raise ArgumentError, "Meilisearch only supports match: :word (got #{options[:match].inspect})"
        end
      end

      # searchableAttributes order is relevance priority in Meilisearch.
      # default to all attributes. When stemming is enabled (Strategy B), the
      # shadow stemmed fields are appended after the originals so verbatim
      # matches keep priority.
      def meilisearch_searchable
        return ["*"] unless options[:searchable]

        base = Array(options[:searchable]).map(&:to_s)
        if Searchkick::Meilisearch::Stemming.enabled?(options)
          base + base.map { |f| "#{f}#{Searchkick::Meilisearch::STEMMED_SUFFIX}" }
        else
          base
        end
      end

      # filterableAttributes must be declared for `where` to work.
      def meilisearch_filterable
        if options.key?(:filterable)
          Array(options[:filterable]).map(&:to_s)
        else
          ["*"]
        end
      end

      # searchkick has no model-level sortable option (order is per-query), but
      # Meilisearch requires sortable attributes declared up front. Mirror the
      # filterable set.
      def meilisearch_sortable
        meilisearch_filterable
      end

      def meilisearch_max_total_hits
        options[:max_result_window] || (options[:deep_paging] ? 1_000_000_000 : 1_000)
      end

      # ES synonyms (equivalent groups or "a => b" directional) ->
      # Meilisearch directional map { "term" => ["synonym", ...] }
      def meilisearch_synonyms
        synonyms = options[:synonyms] || []
        synonyms = synonyms.call if synonyms.respond_to?(:call)

        result = Hash.new { |h, k| h[k] = [] }
        Array(synonyms).each do |group|
          if group.is_a?(String) && group.include?("=>")
            left, right = group.split("=>").map { |side| side.split(",").map { |s| s.strip.downcase } }
            left.each { |term| result[term].concat(right) }
          else
            terms = (group.is_a?(Array) ? group : group.to_s.split(",")).map { |s| s.to_s.strip.downcase }
            terms.each { |term| result[term].concat(terms - [term]) }
          end
        end
        result.transform_values(&:uniq)
      end
    end
  end
end
