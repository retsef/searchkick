module Searchkick
  module Meilisearch
    # suffix for the shadow stemmed field that mirrors a searchable field
    # (Strategy B - simulates an Elasticsearch multi-field)
    STEMMED_SUFFIX = "_searchkick_stemmed".freeze

    # default federation weight for the stemmed (recall) lane, below the exact
    # lane (1.0) so verbatim matches rank higher
    DEFAULT_STEM_WEIGHT = 0.5

    # Resolves per-index stemming configuration from the searchkick model
    # options. Stemming is enabled when a `language` is set on the model.
    module Stemming
      class << self
        def enabled?(options)
          !language(options).nil?
        end

        def language(options)
          lang = options[:language]
          lang = lang.call if lang.respond_to?(:call)
          lang
        end

        # config used by Bulk (index time) and Search (query time)
        def config_for(index_uid)
          model = Searchkick.models.find do |m|
            m.respond_to?(:searchkick_index) && m.searchkick_index.name == index_uid
          end
          return nil unless model

          options = model.searchkick_options
          lang = language(options)
          return nil unless lang

          {
            language: lang,
            searchable: Array(options[:searchable]).map(&:to_s),
            filterable: Array(options[:filterable]).map(&:to_s),
            weight: options[:stem_weight] || Searchkick::Meilisearch::DEFAULT_STEM_WEIGHT
          }
        end
      end
    end

    # Wraps Lingua::Stemmer (the `ruby-stemmer` gem) - libstemmer/Snowball,
    # the same algorithm family Elasticsearch uses by default.
    class Stemmer
      @cache = {}

      class << self
        def for(language)
          @cache[language.to_s] ||= new(language)
        end
      end

      def initialize(language)
        require "lingua/stemmer"
        # searchkick language names (e.g. "english", "italian") match Snowball
        # algorithm names used by ruby-stemmer
        @stemmer = ::Lingua::Stemmer.new(language: language.to_s)
      end

      # stem each word token, leaving separators/punctuation intact
      def stem_text(text)
        return text unless text.is_a?(String)
        text.gsub(/\p{Word}+/) { |word| @stemmer.stem(word) }
      end
    end
  end
end
