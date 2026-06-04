require_relative "stemmer"
require_relative "vectors"

module Searchkick
  module Meilisearch
    # Translates a single Searchkick-generated ES search request into a
    # Meilisearch search, and the Meilisearch response back into an ES-shaped
    # response hash that Searchkick::Results can consume unchanged.
    class Search
      attr_reader :client, :index_uid, :body

      def initialize(client, params)
        @client = client
        @index_uid = Array(params[:index]).first
        @body = (params[:body] || {})

        unsupported = params.keys & [:scroll, :routing, :type]
        if unsupported.any?
          raise NotImplementedError, "Meilisearch does not support: #{unsupported.join(", ")}"
        end
      end

      def execute
        knn = body[:knn] || body["knn"]
        return execute_knn(symbolize(knn)) if knn

        meili_params = build_params

        config = Searchkick::Meilisearch::Stemming.config_for(index_uid)
        if config
          execute_federated(config, meili_params)
        else
          response = client.index(index_uid).search(@query_string, meili_params)
          normalize_response(response)
        end
      rescue ::Meilisearch::ApiError => e
        raise client.translate_error(e)
      end

      private

      # Approximate vector search. Searchkick's knn payload
      # ({field:, query_vector:, k:, filter:}) maps to a Meilisearch
      # `userProvided` embedder query (vector + hybrid, semanticRatio 1.0).
      def execute_knn(knn)
        field = knn[:field].to_s
        vector = knn[:query_vector] || knn[:vector]
        raise Searchkick::InvalidQueryError, "knn requires field and vector" if field.empty? || vector.nil?

        distance = knn[:distance]
        if distance && distance.to_s != "cosine"
          raise Searchkick::InvalidQueryError, "Meilisearch vector search only supports cosine distance (got #{distance.inspect})"
        end

        params = {
          vector: vector,
          hybrid: {embedder: field, semantic_ratio: 1.0},
          show_ranking_score: true
        }
        params[:limit] = body[:size] if body.key?(:size)
        params[:offset] = body[:from] if body.key?(:from)

        filter = build_filter(knn[:filter])
        params[:filter] = filter if filter

        response = client.index(index_uid).search("", params)
        normalize_response(response)
      end

      # Strategy B: run two federated lanes - an exact lane on the original
      # fields (weight 1.0) and a stemmed lane on the shadow stemmed fields
      # (weight < 1.0). Meilisearch merges, dedupes by document, and ranks by
      # weighted ranking score, so verbatim matches outrank stem-only matches
      # while morphological recall is preserved.
      def execute_federated(config, meili_params)
        params = meili_params.dup
        # pagination is controlled by the federation block, not per query
        limit = params.delete(:limit)
        offset = params.delete(:offset)

        raw_term = @query_string
        stemmed_term = Searchkick::Meilisearch::Stemmer.for(config[:language]).stem_text(raw_term)

        searchable = config[:searchable].any? ? config[:searchable] : nil
        stemmed_attrs = (searchable || ["*"]).map { |f| "#{f}#{Searchkick::Meilisearch::STEMMED_SUFFIX}" }

        exact_lane = params.merge(index_uid: index_uid, q: raw_term, federation_options: {weight: 1.0})
        exact_lane[:attributes_to_search_on] = searchable if searchable

        stem_lane = params.merge(
          index_uid: index_uid,
          q: stemmed_term,
          attributes_to_search_on: stemmed_attrs,
          federation_options: {weight: config[:weight]}
        )

        federation = {}
        federation[:limit] = limit unless limit.nil?
        federation[:offset] = offset unless offset.nil?
        # merge facet distributions across both lanes into a single top-level
        # facetDistribution (otherwise federation returns facetsByIndex)
        federation[:merge_facets] = {} if params[:facets]

        response = client.ms.multi_search(queries: [exact_lane, stem_lane], federation: federation)
        normalize_response(response)
      end

      # ES body -> Meilisearch search params
      def build_params
        reject_unsupported_top_level!

        @query_string = extract_query_string(body[:query] || body["query"])

        params = {}

        # pagination (ES from/size -> Meilisearch offset/limit)
        params[:limit] = body[:size] if body.key?(:size)
        params[:offset] = body[:from] if body.key?(:from)

        # filters (ES bool.filter / where -> Meilisearch filter expression)
        filter = build_filter(body[:query] || body["query"])
        params[:filter] = filter if filter

        # sort
        sort = build_sort(body[:sort])
        params[:sort] = sort if sort && sort.any?

        # facets (ES terms aggs -> Meilisearch facets)
        facets = build_facets(body[:aggs])
        params[:facets] = facets if facets && facets.any?

        # highlighting (ES highlight -> Meilisearch attributesToHighlight)
        highlight = build_highlight(body[:highlight])
        if highlight
          params[:attributes_to_highlight] = highlight[:fields]
          params[:highlight_pre_tag] = highlight[:pre_tag] if highlight[:pre_tag]
          params[:highlight_post_tag] = highlight[:post_tag] if highlight[:post_tag]
        end

        # ranking score so Results#with_score works
        params[:show_ranking_score] = true

        params
      end

      def reject_unsupported_top_level!
        if body.key?(:suggest) || body.key?("suggest")
          raise Searchkick::InvalidQueryError, "suggestions (suggest:) are not supported by Meilisearch"
        end
        if body.key?(:post_filter) || body.key?("post_filter")
          raise Searchkick::InvalidQueryError, "post_filter (smart_aggs) is not supported by this Meilisearch adapter"
        end
        if body[:explain] || body[:profile]
          raise Searchkick::InvalidQueryError, "explain/profile are not supported by Meilisearch"
        end
        if body[:indices_boost]
          raise Searchkick::InvalidQueryError, "indices_boost is not supported by Meilisearch"
        end
      end

      # Walk the ES query tree to recover the user's search term. Every match
      # clause Searchkick emits carries the same `query` string. function_score
      # / script_score / more_like_this / rank_feature have no Meilisearch
      # equivalent and raise.
      def extract_query_string(query)
        return "" if query.nil?
        query = query.transform_keys(&:to_sym) if query.is_a?(Hash)

        if query.key?(:match_all)
          ""
        elsif query.key?(:bool)
          bool = symbolize(query[:bool])
          # the term lives in must/should; filter is handled separately
          clause = bool[:must] || bool[:should]
          extract_query_string_from_clause(clause)
        elsif query.key?(:function_score)
          raise Searchkick::InvalidQueryError, "boost_by/boost_where/conversions (function_score) are not supported by Meilisearch"
        elsif query.key?(:script_score)
          raise Searchkick::InvalidQueryError, "script scoring is not supported by Meilisearch"
        elsif query.key?(:more_like_this)
          raise Searchkick::InvalidQueryError, "similar: (more_like_this) is not supported by Meilisearch"
        elsif query.key?(:rank_feature)
          raise Searchkick::InvalidQueryError, "conversions_v2 (rank_feature) is not supported by Meilisearch"
        elsif query.key?(:nested)
          raise Searchkick::InvalidQueryError, "conversions (nested) are not supported by Meilisearch"
        else
          extract_query_string_from_clause(query)
        end
      end

      def extract_query_string_from_clause(clause)
        return "" if clause.nil?
        found = find_match_query(clause)
        found || ""
      end

      # depth-first search for the first match/match_phrase/multi_match `query`
      def find_match_query(node)
        case node
        when Array
          node.each do |child|
            v = find_match_query(child)
            return v if v
          end
          nil
        when Hash
          node = symbolize(node)
          if node.key?(:function_score) || node.key?(:script_score) ||
             node.key?(:more_like_this) || node.key?(:rank_feature) || node.key?(:nested)
            return extract_query_string({node.keys.first => node.values.first})
          end

          [:match, :match_phrase].each do |mt|
            if node[mt]
              inner = symbolize(node[mt].values.first)
              return inner[:query].to_s
            end
          end
          if node[:multi_match]
            return symbolize(node[:multi_match])[:query].to_s
          end

          node.each_value do |v|
            found = find_match_query(v)
            return found if found
          end
          nil
        else
          nil
        end
      end

      # ES bool.filter -> Meilisearch filter expression string
      def build_filter(query)
        return nil if query.nil?
        query = symbolize(query)
        return nil unless query.key?(:bool)

        filters = Array(symbolize(query[:bool])[:filter])
        return nil if filters.empty?

        expr = filters.map { |f| translate_filter(f) }.compact
        return nil if expr.empty?
        expr.join(" AND ")
      end

      def translate_filter(node)
        node = symbolize(node)
        key = node.keys.first

        case key
        when :term
          field, spec = node[:term].first
          value = spec.is_a?(Hash) ? symbolize(spec)[:value] : spec
          "#{filter_field(field)} = #{quote(value)}"
        when :terms
          field, values = node[:terms].first
          "#{filter_field(field)} IN [#{values.map { |v| quote(v) }.join(", ")}]"
        when :range
          field, spec = node[:range].first
          translate_range(field, symbolize(spec))
        when :exists
          "#{filter_field(symbolize(node[:exists])[:field])} EXISTS"
        when :bool
          translate_bool_filter(symbolize(node[:bool]))
        when :geo_distance
          translate_geo_distance(symbolize(node[:geo_distance]))
        when :geo_polygon, :geo_shape
          raise Searchkick::InvalidQueryError, "#{key} filter is not supported by Meilisearch"
        when :geo_bounding_box
          raise Searchkick::InvalidQueryError, "geo bounding box filter is not supported by this Meilisearch adapter"
        when :regexp
          raise Searchkick::InvalidQueryError, "regexp / like filters are not supported by Meilisearch"
        when :prefix
          raise Searchkick::InvalidQueryError, "prefix filter is not supported by Meilisearch"
        when :script
          raise Searchkick::InvalidQueryError, "script (where _script:) filters are not supported by Meilisearch"
        else
          raise Searchkick::InvalidQueryError, "unsupported filter: #{key}"
        end
      end

      def translate_bool_filter(bool)
        if bool[:must_not]
          inner = Array(bool[:must_not]).map { |f| translate_filter(f) }.compact
          if inner.size == 1 && inner.first.end_with?(" EXISTS")
            # exists:false -> NOT EXISTS
            return inner.first.sub(/ EXISTS\z/, " NOT EXISTS")
          end
          "NOT (#{inner.join(" AND ")})"
        elsif bool[:should]
          inner = Array(bool[:should]).map { |f| translate_filter(f) }.compact
          "(#{inner.join(" OR ")})"
        elsif bool[:must]
          inner = Array(bool[:must]).map { |f| translate_filter(f) }.compact
          "(#{inner.join(" AND ")})"
        elsif bool[:filter]
          inner = Array(bool[:filter]).map { |f| translate_filter(f) }.compact
          "(#{inner.join(" AND ")})"
        else
          raise Searchkick::InvalidQueryError, "unsupported bool filter: #{bool.keys.join(", ")}"
        end
      end

      def translate_range(field, spec)
        parts = []
        parts << "#{filter_field(field)} > #{quote(spec[:gt])}" if spec.key?(:gt)
        parts << "#{filter_field(field)} >= #{quote(spec[:gte])}" if spec.key?(:gte)
        parts << "#{filter_field(field)} < #{quote(spec[:lt])}" if spec.key?(:lt)
        parts << "#{filter_field(field)} <= #{quote(spec[:lte])}" if spec.key?(:lte)
        "(#{parts.join(" AND ")})"
      end

      # ES geo_distance {field => [lon, lat], distance: "50mi"} -> _geoRadius
      def translate_geo_distance(spec)
        distance = spec.delete(:distance)
        field, coords = spec.first
        lon, lat = coords
        meters = parse_distance(distance)
        "_geoRadius(#{lat}, #{lon}, #{meters})"
      end

      def parse_distance(distance)
        return distance if distance.is_a?(Numeric)
        m = distance.to_s.match(/\A([\d.]+)\s*(mi|km|m)?\z/)
        raise Searchkick::InvalidQueryError, "unsupported distance: #{distance}" unless m
        value = m[1].to_f
        case m[2]
        when "mi" then (value * 1609.34).round
        when "km" then (value * 1000).round
        else value.round
        end
      end

      # `id` is mapped to `_id` by Searchkick's where builder; map it back to
      # the Meilisearch primary key.
      def filter_field(field)
        field = field.to_s
        field == "_id" ? Searchkick::Meilisearch::PRIMARY_KEY : field
      end

      def quote(value)
        case value
        when Numeric, true, false
          value.to_s
        when nil
          "null"
        else
          "\"#{value.to_s.gsub('"', '\\"')}\""
        end
      end

      # ES sort -> Meilisearch ["field:asc", ...]
      def build_sort(sort)
        return nil if sort.nil?
        Array(sort).flat_map do |entry|
          case entry
          when String, Symbol
            next [] if entry.to_s == "_doc" || entry.to_s == "_score"
            ["#{entry}:asc"]
          when Hash
            entry.map do |field, spec|
              direction = spec.is_a?(Hash) ? (symbolize(spec)[:order] || "asc") : spec
              if field.to_s == "_geo_distance"
                raise Searchkick::InvalidQueryError, "geo distance sort requires _geoPoint - not implemented in this adapter"
              end
              next nil if field.to_s == "_score"
              "#{field}:#{direction}"
            end.compact
          else
            []
          end
        end
      end

      # ES aggs -> Meilisearch facets (terms aggregations only)
      def build_facets(aggs)
        return nil if aggs.nil?
        aggs.map do |field, agg_options|
          agg_options = symbolize(agg_options)
          if agg_options.key?(:terms)
            symbolize(agg_options[:terms])[:field] || field.to_s
          elsif agg_options.key?(:filter)
            # smart_aggs wraps terms in a filter agg - unwrap one level
            inner = symbolize(symbolize(agg_options[:aggs]).values.first)
            if inner.key?(:terms)
              symbolize(inner[:terms])[:field] || field.to_s
            else
              raise Searchkick::InvalidQueryError, "only terms aggregations are supported by Meilisearch"
            end
          else
            raise Searchkick::InvalidQueryError,
              "only terms aggregations are supported by Meilisearch (got #{(agg_options.keys - [:aggs]).join(", ")})"
          end
        end
      end

      def build_highlight(highlight)
        return nil if highlight.nil?
        highlight = symbolize(highlight)
        fields = (highlight[:fields] || {}).keys.map { |f| base_field(f.to_s) }.uniq
        result = {fields: fields}
        result[:pre_tag] = Array(highlight[:pre_tags]).first if highlight[:pre_tags]
        result[:post_tag] = Array(highlight[:post_tags]).first if highlight[:post_tags]
        result
      end

      def base_field(field)
        field.sub(/\.(analyzed|word_start|word_middle|word_end|text_start|text_middle|text_end|exact)\z/, "")
      end

      # --- response normalization -------------------------------------------

      # Meilisearch response -> ES-shaped response hash
      def normalize_response(response)
        response = response.to_h if response.respond_to?(:to_h)
        hits = response["hits"] || []

        total =
          if response.key?("totalHits")
            {"value" => response["totalHits"], "relation" => "eq"}
          else
            {"value" => response["estimatedTotalHits"] || hits.size, "relation" => "gte"}
          end

        es = {
          "took" => response["processingTimeMs"],
          "timed_out" => false,
          "hits" => {
            "total" => total,
            "max_score" => nil,
            "hits" => hits.map { |h| normalize_hit(h) }
          }
        }

        if response["facetDistribution"]
          es["aggregations"] = normalize_facets(response["facetDistribution"])
        end

        es
      end

      # Meilisearch reserved keys + the shadow stemmed fields are stripped from
      # the returned _source so callers never see them.
      RESERVED_HIT_KEYS = %w[_formatted _rankingScore _rankingScoreDetails _federation _vectors].freeze

      def normalize_hit(hit)
        formatted = hit["_formatted"]
        # federated search reports the merged score under _federation
        ranking_score = hit["_rankingScore"] || hit.dig("_federation", "weightedRankingScore")
        source = hit.reject { |k, _| reserved_or_stemmed?(k) }

        es_hit = {
          "_index" => index_uid,
          "_id" => hit[Searchkick::Meilisearch::PRIMARY_KEY].to_s,
          "_score" => ranking_score,
          "_source" => source
        }

        if formatted
          highlight = {}
          formatted.each do |field, value|
            next if reserved_or_stemmed?(field)
            highlight[field] = [value] if source.key?(field) && value != source[field]
          end
          es_hit["highlight"] = highlight unless highlight.empty?
        end

        es_hit
      end

      def reserved_or_stemmed?(key)
        RESERVED_HIT_KEYS.include?(key) || key.to_s.end_with?(Searchkick::Meilisearch::STEMMED_SUFFIX)
      end

      # Meilisearch facetDistribution -> ES terms aggregation buckets
      def normalize_facets(distribution)
        distribution.each_with_object({}) do |(field, counts), result|
          buckets = counts.map { |key, count| {"key" => key, "doc_count" => count} }
          buckets.sort_by! { |b| -b["doc_count"] }
          result[field] = {"buckets" => buckets}
        end
      end

      def symbolize(hash)
        hash.is_a?(Hash) ? hash.transform_keys { |k| k.to_s.to_sym } : hash
      end
    end

    # Multi-search: ES msearch body (alternating header/body pairs) ->
    # Meilisearch multi_search.
    class MultiSearch
      def initialize(client, params)
        @client = client
        @body = params[:body] || []
      end

      def execute
        pairs = @body.each_slice(2).to_a
        queries = pairs.map do |header, search_body|
          header = header.transform_keys(&:to_sym)
          index_uid = Array(header[:index]).first
          search = Searchkick::Meilisearch::Search.new(@client, index: index_uid, body: search_body)
          meili = search.send(:build_params)
          {index_uid: index_uid, q: search.instance_variable_get(:@query_string)}.merge(meili)
        end

        results = @client.ms.multi_search(queries)["results"]

        normalized = pairs.each_with_index.map do |(header, search_body), i|
          index_uid = Array(header.transform_keys(&:to_sym)[:index]).first
          search = Searchkick::Meilisearch::Search.new(@client, index: index_uid, body: search_body)
          search.send(:normalize_response, results[i])
        end

        {"responses" => normalized}
      rescue ::Meilisearch::ApiError => e
        raise @client.translate_error(e)
      end
    end
  end
end
