module Searchkick
  module Meilisearch
    # Translates ES bulk action items into Meilisearch document operations.
    #
    # Searchkick emits items shaped like:
    #   {index:  {_index:, _id:, data: {...}}}            # upsert
    #   {update: {_index:, _id:, data: {doc: {...}}}}     # partial update
    #   {delete: {_index:, _id:}}                         # delete
    #
    # Meilisearch is async; we wait for each task so callers see ES-like sync
    # behavior. Returns an ES-shaped bulk response.
    class Bulk
      def initialize(client, items)
        @client = client
        @items = items
      end

      def execute
        # group consecutive operations by (operation, index) to batch them
        adds = Hash.new { |h, k| h[k] = [] }     # index_uid => [docs]
        updates = Hash.new { |h, k| h[k] = [] }  # index_uid => [docs]
        deletes = Hash.new { |h, k| h[k] = [] }  # index_uid => [ids]

        @items.each do |item|
          item = item.transform_keys(&:to_sym)
          if item.key?(:index)
            meta = item[:index]
            adds[meta[:_index]] << document_for(meta)
          elsif item.key?(:update)
            meta = item[:update]
            updates[meta[:_index]] << document_for(meta, partial: true)
          elsif item.key?(:delete)
            meta = item[:delete]
            deletes[meta[:_index]] << meta[:_id]
          else
            raise Searchkick::InvalidQueryError, "unsupported bulk action: #{item.keys.first}"
          end
        end

        tasks = []
        adds.each do |index_uid, docs|
          tasks << @client.index(index_uid).add_documents(docs, Searchkick::Meilisearch::PRIMARY_KEY)
        end
        updates.each do |index_uid, docs|
          tasks << @client.index(index_uid).update_documents(docs, Searchkick::Meilisearch::PRIMARY_KEY)
        end
        deletes.each do |index_uid, ids|
          tasks << @client.index(index_uid).delete_documents(ids)
        end

        tasks.each { |task| @client.wait_for_task(task) }

        {"errors" => false, "items" => []}
      rescue ::Meilisearch::ApiError => e
        raise @client.translate_error(e)
      end

      private

      # build a Meilisearch document from a bulk meta entry, injecting the
      # primary key (ES keeps `_id` out of `_source`; Meilisearch needs it in)
      def document_for(meta, partial: false)
        data = meta[:data]
        source = partial ? data[:doc] : data
        source = source.dup
        source[Searchkick::Meilisearch::PRIMARY_KEY] ||= meta[:_id]
        source
      end
    end
  end
end
