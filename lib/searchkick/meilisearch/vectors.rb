module Searchkick
  module Meilisearch
    # Resolves the vector (knn) fields for an index from the searchkick model
    # options. Used by Bulk (to move vectors into `_vectors`) and Search.
    module Vectors
      # Meilisearch stores user-provided embeddings under this document key
      KEY = "_vectors".freeze

      def self.fields_for(index_uid)
        model = Searchkick.models.find do |m|
          m.respond_to?(:searchkick_index) && m.searchkick_index.name == index_uid
        end
        return [] unless model

        (model.searchkick_options[:knn] || {}).keys.map(&:to_s)
      end
    end
  end
end
