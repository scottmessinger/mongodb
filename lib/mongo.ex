defmodule Mongo do
  @moduledoc """
  The main entry point for doing queries. All functions take a pool to
  run the query on.

  ## Generic options

  All operations take these options.

    * `:timeout` - TODO

  ## Read options

  All read operations that returns a cursor take the following options
  for controlling the behaviour of the cursor.

    * `:batch_size` - Number of documents to fetch in each batch
    * `:limit` - Maximum number of documents to fetch with the cursor

  ## Write options

  All write operations take the following options for controlling the
  write concern.

    * `:w` - The number of servers to replicate to before returning from write
      operators, a 0 value will return immediately, :majority will wait until
      the operation propagates to a majority of members in the replica set
      (Default: 1)
    * `:j` If true, the write operation will only return after it has been
      committed to journal - (Default: false)
    * `:wtimeout` - If the write concern is not satisfied in the specified
      interval, the operation returns an error

  ## Logging

  All operations take a boolean `log` option, that determines, whether the
  pool's `log/5` function will be called.
  """

  use Bitwise
  use Mongo.Messages
  alias Mongo.Query

  @timeout 5000

  @type conn :: DbConnection.Conn
  @type collection :: String.t
  @opaque cursor :: Mongo.Cursor.t | Mongo.AggregationCursor.t | Mongo.SinglyCursor.t
  @type result(t) :: :ok | {:ok, t} | {:error, Mongo.Error.t}
  @type result!(t) :: nil | t | no_return

  defmacrop bangify(result) do
    quote do
      case unquote(result) do
        {:ok, value}    -> value
        {:error, error} -> raise error
        :ok             -> nil
      end
    end
  end

  # TODO: docs
  @spec start_link(Keyword.t) :: {:ok, pid} | {:error, Mongo.Error.t | term}
  def start_link(opts) do
    DBConnection.start_link(Mongo.Protocol, opts)
  end

  @doc """
  Create a supervisor child specification for a pool of connections.

  See `Supervisor.Spec` for child options (`child_opts`).

  See `start_link/1` for connection options (`opts`).
  """
  @spec child_spec(Keyword.t, Keyword.t) :: Supervisor.Spec.spec
  def child_spec(opts, child_opts \\ []) do
    DBConnection.child_spec(Mongo.Protocol, opts, child_opts)
  end

  @doc """
  Generates a new `BSON.ObjectId`.
  """
  @spec object_id :: BSON.ObjectId.t
  def object_id do
    Mongo.IdServer.new
  end

  @doc """
  Performs aggregation operation using the aggregation pipeline.

  ## Options

    * `:allow_disk_use` - Enables writing to temporary files (Default: false)
    * `:max_time` - Specifies a time limit in milliseconds
    * `:use_cursor` - Use a cursor for a batched response (Default: true)
  """
  @spec aggregate(conn, collection, [BSON.document], Keyword.t) :: cursor
  def aggregate(conn, coll, pipeline, opts \\ []) do
    query = [
      aggregate: coll,
      pipeline: pipeline,
      allowDiskUse: opts[:allow_disk_use],
      maxTimeMS: opts[:max_time]
    ] |> filter_nils

    version = Mongo.Monitor.wire_version(conn)
    cursor? = version >= 1 and Keyword.get(opts, :use_cursor, true)
    opts = Keyword.drop(opts, ~w(allow_disk_use max_time use_cursor)a)

    if cursor? do
      query = query ++ [cursor: filter_nils(%{batchSize: opts[:batch_size]})]
      aggregation_cursor(conn, "$cmd", query, nil, opts)
    else
      singly_cursor(conn, "$cmd", query, nil, opts)
    end
  end

  @doc """
  The `find_and_modify` command modifies and returns a single document.
  By default, the returned document does not include the modifications made on the update.
  To return the document with the modifications made on the update, use the `new` option.
  [(From the MongoDB Docs)](https://docs.mongodb.com/manual/reference/command/findAndModify/)

  ## Options
    * `:sort` - Determines which document the operation modifies if the query selects multiple documents.
                findAndModify modifies the first document in the sort order specified by this argument.
    * `:remove` - Boolean. Removes the document (default `:false`)
    * `:update` -  Boolean. Updates the document (default `:true`)
    * `:new` -     Boolean. Returns the modified document instead of the original (default `:false`)
    * `:fields` -  A subset of fields to return. Will return fields from the new document
    * `:upsert` -  Create a document if no document matches the query or updates the document.
                   Used in conjunction with `update`
    * `:bypass_document_validation` -  Bypasses document validation during the operation
    * `:write_concern` -  Specify the write condition
    * `:max_time` - Specifies a time limit in milliseconds for processing the operation.

  """
  @type find_and_modify_opts :: [
    sort: %{},
    remove: boolean,
    new: boolean,
    fields: %{},
    upsert: boolean,
    bypassDocumentValidation: boolean,
    writeConcern: %{}
  ]
  @spec find_and_modify(conn, collection, BSON.document, find_and_modify_opts) :: %{value: %{}, lastErrorObject: %{}, ok: non_neg_integer}
  def find_and_modify(conn, coll, filter, update, opts \\ []) do
    query = [
      findAndModify:            coll,
      query:                    filter,
      update:                   update,
      remove:                   opts[:remove],
      new:                      opts[:new],
      fields:                   opts[:fields],
      upsert:                   opts[:upsert],
      bypassDocumentValidation: opts[:bypass_document_validation],
      writeConcern:             opts[:write_concern],
      maxTimeMS:                opts[:max_time]
    ] |> filter_nils

    opts = Keyword.drop(opts, ~w(new fields remove upsert bypass_document_validation write_concern max_time)a)

    with {:ok, doc} <- command(conn, query, opts), do: {:ok, doc}
  end

  @doc """
  Returns the count of documents that would match a `find/4` query.

  ## Options

    * `:limit` - Maximum number of documents to fetch with the cursor
    * `:skip` - Number of documents to skip before returning the first
    * `:hint` - Hint which index to use for the query
  """
  @spec count(conn, collection, BSON.document, Keyword.t) :: result(non_neg_integer)
  def count(conn, coll, filter, opts \\ []) do
    query = [
      count: coll,
      query: filter,
      limit: opts[:limit],
      skip: opts[:skip],
      hint: opts[:hint]
    ] |> filter_nils

    opts = Keyword.drop(opts, ~w(limit skip hint)a)

    # Mongo 2.4 and 2.6 returns a float
    with {:ok, doc} <- command(conn, query, opts),
         do: {:ok, trunc(doc["n"])}
  end

  @doc """
  Similar to `count/4` but unwraps the result and raises on error.
  """
  @spec count!(conn, collection, BSON.document, Keyword.t) :: result!(non_neg_integer)
  def count!(conn, coll, filter, opts \\ []) do
    bangify(count(conn, coll, filter, opts))
  end

  @doc """
  Finds the distinct values for a specified field across a collection.

  ## Options

    * `:max_time` - Specifies a time limit in milliseconds
  """
  @spec distinct(conn, collection, String.t | atom, BSON.document, Keyword.t) :: result([BSON.t])
  def distinct(conn, coll, field, filter, opts \\ []) do
    query = [
      distinct: coll,
      key: field,
      query: filter,
      maxTimeMS: opts[:max_time]
    ] |> filter_nils

    opts = Keyword.drop(opts, ~w(max_time))

    with {:ok, doc} <- command(conn, query, opts),
         do: {:ok, doc["values"]}
  end

  @doc """
  Similar to `distinct/5` but unwraps the result and raises on error.
  """
  @spec distinct!(conn, collection, String.t | atom, BSON.document, Keyword.t) :: result!([BSON.t])
  def distinct!(conn, coll, field, filter, opts \\ []) do
    bangify(distinct(conn, coll, field, filter, opts))
  end

  @doc """
  Selects documents in a collection and returns a cursor for the selected
  documents.

  ## Options

    * `:comment` - Associates a comment to a query
    * `:cursor_type` - Set to :tailable or :tailable_await to return a tailable
      cursor
    * `:max_time` - Specifies a time limit in milliseconds
    * `:modifiers` - Meta-operators modifying the output or behavior of a query,
      see http://docs.mongodb.org/manual/reference/operator/query-modifier/
    * `:cursor_timeout` - Set to false if cursor should not close after 10
      minutes (Default: true)
    * `:order_by` - Sorts the results of a query in ascending or descending order
    * `:projection` - Limits the fields to return for all matching document
    * `:skip` - The number of documents to skip before returning (Default: 0)
  """
  @spec find(conn, collection, BSON.document, Keyword.t) :: cursor
  def find(conn, coll, filter, opts \\ []) do
    query = [
      {"$comment", opts[:comment]},
      {"$maxTimeMS", opts[:max_time]},
      {"$orderby", opts[:sort]}
    ] ++ Enum.into(opts[:modifiers] || [], [])

    query = filter_nils(query)

    query =
      if query == [] do
        filter
      else
        filter = normalize_doc(filter)
        filter = if List.keymember?(filter, "$query", 0), do: filter, else: [{"$query", filter}]
        filter ++ query
      end

    select = opts[:projection]
    opts = if Keyword.get(opts, :cursor_timeout, true), do: opts, else: [{:no_cursor_timeout, true}|opts]
    drop = ~w(comment max_time modifiers sort cursor_type projection cursor_timeout)a
    opts = cursor_type(opts[:cursor_type]) ++ Keyword.drop(opts, drop)

    cursor(conn, coll, query, select, opts)
  end

  @doc false
  def raw_find(conn, coll, query, select, opts) do
    params = [query, select]
    query = %Query{action: :find, extra: coll}
    with {:ok, reply} <- DBConnection.execute(conn, query, params, defaults(opts)),
         :ok <- maybe_failure(reply),
         op_reply(docs: docs, cursor_id: cursor_id, from: from, num: num) = reply,
         do: {:ok, %{from: from, num: num, cursor_id: cursor_id, docs: docs}}
  end

  @doc false
  def get_more(conn, coll, cursor, opts) do
    query = %Query{action: :get_more, extra: {coll, cursor}}
    with {:ok, reply} <- DBConnection.execute(conn, query, [], defaults(opts)),
         :ok <- maybe_failure(reply),
         op_reply(docs: docs, cursor_id: cursor_id, from: from, num: num) = reply,
         do: {:ok, %{from: from, num: num, cursor_id: cursor_id, docs: docs}}
  end

  @doc false
  def kill_cursors(conn, cursor_ids, opts) do
    query = %Query{action: :kill_cursors, extra: cursor_ids}
    with {:ok, :ok} <- DBConnection.execute(conn, query, [], defaults(opts)),
         do: :ok
  end

  @doc """
  Issue a database command. If the command has parameters use a keyword
  list for the document because the "command key" has to be the first
  in the document.
  """
  @spec command(conn, BSON.document, Keyword.t) :: result(BSON.document)
  def command(conn, query, opts \\ []) do
    params = [query]
    query = %Query{action: :command}
    with {:ok, reply} <- DBConnection.execute(conn, query, params, defaults(opts)),
         :ok <- maybe_failure(reply) do
      case reply do
        op_reply(docs: [%{"ok" => 1.0} = doc]) ->
          {:ok, doc}
        op_reply(docs: [%{"ok" => 0.0, "errmsg" => reason} = error]) ->
          {:error, %Mongo.Error{message: "command failed: #{reason}", code: error["code"]}}
        # TODO: Check if needed
        op_reply(docs: []) ->
          {:ok, nil}
      end
    end
  end

  @doc """
  Similar to `command/3` but unwraps the result and raises on error.
  """
  @spec command!(conn, BSON.document, Keyword.t) :: result!(BSON.document)
  def command!(conn, query, opts \\ []) do
    bangify(command(conn, query, opts))
  end

  @doc """
  Insert a single document into the collection.

  If the document is missing the `_id` field or it is `nil`, an ObjectId
  will be generated, inserted into the document, and returned in the result struct.
  """
  @spec insert_one(conn, collection, BSON.document, Keyword.t) :: result(Mongo.InsertOneResult.t)
  def insert_one(conn, coll, doc, opts \\ []) do
    assert_single_doc!(doc)
    {[id], [doc]} = assign_ids([doc])

    params = [doc]
    query = %Query{action: :insert_one, extra: coll}
    with {:ok, reply} <- DBConnection.execute(conn, query, params, defaults(opts)),
         :ok <- maybe_failure(reply),
         {:ok, _doc} <- get_last_error(reply),
         do: {:ok, %Mongo.InsertOneResult{inserted_id: id}}
  end

  @doc """
  Similar to `insert_one/4` but unwraps the result and raises on error.
  """
  @spec insert_one!(conn, collection, BSON.document, Keyword.t) :: result!(Mongo.InsertOneResult.t)
  def insert_one!(conn, coll, doc, opts \\ []) do
    bangify(insert_one(conn, coll, doc, opts))
  end

  @doc """
  Insert multiple documents into the collection.

  If any of the documents is missing the `_id` field or it is `nil`, an ObjectId
  will be generated, and insertd into the document.
  Ids of all documents will be returned in the result struct.

  ## Options

    * `:continue_on_error` - even if insert fails for one of the documents
      continue inserting the remaining ones (default: `false`)
  """
  # TODO describe the ordered option
  @spec insert_many(conn, collection, [BSON.document], Keyword.t) :: result(Mongo.InsertManyResult.t)
  def insert_many(conn, coll, docs, opts \\ []) do
    assert_many_docs!(docs)
    {ids, docs} = assign_ids(docs)

    # NOTE: Only for 2.4
    ordered? = Keyword.get(opts, :ordered, true)
    opts = [continue_on_error: not ordered?] ++ opts

    params = docs
    query = %Query{action: :insert_many, extra: coll}
    with {:ok, reply} <- DBConnection.execute(conn, query, params, defaults(opts)),
         :ok <- maybe_failure(reply),
         {:ok, _doc} <- get_last_error(reply),
         ids = index_map(ids, 0, %{}),
         do: {:ok, %Mongo.InsertManyResult{inserted_ids: ids}}
  end

  @doc """
  Similar to `insert_many/4` but unwraps the result and raises on error.
  """
  @spec insert_many!(conn, collection, [BSON.document], Keyword.t) :: result!(Mongo.InsertManyResult.t)
  def insert_many!(conn, coll, docs, opts \\ []) do
    bangify(insert_many(conn, coll, docs, opts))
  end

  @doc """
  Remove a document matching the filter from the collection.
  """
  @spec delete_one(conn, collection, BSON.document, Keyword.t) :: result(Mongo.DeleteResult.t)
  def delete_one(conn, coll, filter, opts \\ []) do
    params = [filter]
    query = %Query{action: :delete_one, extra: coll}
    with {:ok, reply} <- DBConnection.execute(conn, query, params, defaults(opts)),
         :ok <- maybe_failure(reply),
         {:ok, %{"n" => n}} <- get_last_error(reply),
         do: {:ok, %Mongo.DeleteResult{deleted_count: n}}
  end

  @doc """
  Similar to `delete_one/4` but unwraps the result and raises on error.
  """
  @spec delete_one!(conn, collection, BSON.document, Keyword.t) :: result!(Mongo.DeleteResult.t)
  def delete_one!(conn, coll, filter, opts \\ []) do
    bangify(delete_one(conn, coll, filter, opts))
  end

  @doc """
  Remove all documents matching the filter from the collection.
  """
  @spec delete_many(conn, collection, BSON.document, Keyword.t) :: result(Mongo.DeleteResult.t)
  def delete_many(conn, coll, filter, opts \\ []) do
    params = [filter]
    query = %Query{action: :delete_many, extra: coll}
    with {:ok, reply} <- DBConnection.execute(conn, query, params, defaults(opts)),
         :ok <- maybe_failure(reply),
         {:ok, %{"n" => n}} <- get_last_error(reply),
         do: {:ok, %Mongo.DeleteResult{deleted_count: n}}
end

  @doc """
  Similar to `delete_many/4` but unwraps the result and raises on error.
  """
  @spec delete_many!(conn, collection, BSON.document, Keyword.t) :: result!(Mongo.DeleteResult.t)
  def delete_many!(conn, coll, filter, opts \\ []) do
    bangify(delete_many(conn, coll, filter, opts))
  end

  @doc """
  Replace a single document matching the filter with the new document.

  ## Options

    * `:upsert` - if set to `true` creates a new document when no document
      matches the filter (default: `false`)
  """
  @spec replace_one(conn, collection, BSON.document, BSON.document, Keyword.t) :: result(Mongo.UpdateResult.t)
  def replace_one(conn, coll, filter, replacement, opts \\ []) do
    modifier_docs(replacement, :replace)

    params = [filter, replacement]
    query = %Query{action: :replace_one, extra: coll}
    with {:ok, reply} <- DBConnection.execute(conn, query, params, defaults(opts)),
         :ok <- maybe_failure(reply),
         {:ok, doc} <- get_last_error(reply) do
      case doc do
        %{"n" => 1, "upserted" => upserted_id} ->
          {:ok, %Mongo.UpdateResult{matched_count: 0, modified_count: 1, upserted_id: upserted_id}}
        %{"n" => n} ->
          {:ok, %Mongo.UpdateResult{matched_count: n, modified_count: n}}
      end
    end
  end

  @doc """
  Similar to `replace_one/5` but unwraps the result and raises on error.
  """
  @spec replace_one!(conn, collection, BSON.document, BSON.document, Keyword.t) :: result!(Mongo.UpdateResult.t)
  def replace_one!(conn, coll, filter, replacement, opts \\ []) do
    bangify(replace_one(conn, coll, filter, replacement, opts))
  end

  @doc """
  Update a single document matching the filter.

  Uses MongoDB update operators to specify the updates. For more information
  please refer to the
  [MongoDB documentation](http://docs.mongodb.org/manual/reference/operator/update/)

  Example:

      Mongo.update_one(MongoPool,
        "my_test_collection",
        %{"filter_field": "filter_value"},
        %{"$set": %{"modified_field": "new_value"}})

  ## Options

    * `:upsert` - if set to `true` creates a new document when no document
      matches the filter (default: `false`)
  """
  @spec update_one(conn, collection, BSON.document, BSON.document, Keyword.t) :: result(Mongo.UpdateResult.t)
  def update_one(conn, coll, filter, update, opts \\ []) do
    modifier_docs(update, :update)

    params = [filter, update]
    query = %Query{action: :update_one, extra: coll}
    with {:ok, reply} <- DBConnection.execute(conn, query, params, defaults(opts)),
         :ok <- maybe_failure(reply),
         {:ok, doc} <- get_last_error(reply) do
      case doc do
        %{"n" => 1, "upserted" => upserted_id} ->
          {:ok, %Mongo.UpdateResult{matched_count: 0, modified_count: 1, upserted_id: upserted_id}}
        %{"n" => n} ->
          {:ok, %Mongo.UpdateResult{matched_count: n, modified_count: n}}
        end
    end
  end

  @doc """
  Similar to `update_one/5` but unwraps the result and raises on error.
  """
  @spec update_one!(conn, collection, BSON.document, BSON.document, Keyword.t) :: result!(Mongo.UpdateResult.t)
  def update_one!(conn, coll, filter, update, opts \\ []) do
    bangify(update_one(conn, coll, filter, update, opts))
  end

  @doc """
  Update all documents matching the filter.

  Uses MongoDB update operators to specify the updates. For more information
  please refer to the
  [MongoDB documentation](http://docs.mongodb.org/manual/reference/operator/update/)

  ## Options

    * `:upsert` - if set to `true` creates a new document when no document
      matches the filter (default: `false`)
  """
  @spec update_many(conn, collection, BSON.document, BSON.document, Keyword.t) :: result(Mongo.UpdateResult.t)
  def update_many(conn, coll, filter, update, opts \\ []) do
    modifier_docs(update, :update)

    params = [filter, update]
    query = %Query{action: :update_many, extra: coll}
    with {:ok, reply} <- DBConnection.execute(conn, query, params, defaults(opts)),
         :ok <- maybe_failure(reply),
         {:ok, doc} <- get_last_error(reply) do
      case doc do
        %{"n" => 1, "upserted" => upserted_id} ->
          {:ok, %Mongo.UpdateResult{matched_count: 0, modified_count: 1, upserted_id: upserted_id}}
        %{"n" => n} ->
          {:ok, %Mongo.UpdateResult{matched_count: n, modified_count: n}}
      end
    end
  end

  @doc """
  Similar to `update_many/5` but unwraps the result and raises on error.
  """
  @spec update_many!(conn, collection, BSON.document, BSON.document, Keyword.t) :: result!(Mongo.UpdateResult.t)
  def update_many!(conn, coll, filter, update, opts \\ []) do
    bangify(update_many(conn, coll, filter, update, opts))
  end

  defp modifier_docs([{key, _}|_], type),
    do: key |> key_to_string |> modifier_key(type)
  defp modifier_docs(map, _type) when is_map(map) and map_size(map) == 0,
    do: :ok
  defp modifier_docs(map, type) when is_map(map),
    do: Enum.at(map, 0) |> elem(0) |> key_to_string |> modifier_key(type)
  defp modifier_docs(list, type) when is_list(list),
    do: Enum.map(list, &modifier_docs(&1, type))

  defp modifier_key(<<?$, _::binary>>, :replace),
    do: raise(ArgumentError, "replace does not allow atomic modifiers")
  defp modifier_key(<<?$, _::binary>>, :update),
    do: :ok
  defp modifier_key(<<_, _::binary>>, :update),
    do: raise(ArgumentError, "update only allows atomic modifiers")
  defp modifier_key(_, _),
    do: :ok

  defp key_to_string(key) when is_atom(key),
    do: Atom.to_string(key)
  defp key_to_string(key) when is_binary(key),
    do: key

  defp cursor(conn, coll, query, select, opts) do
    %Mongo.Cursor{
      conn: conn,
      coll: coll,
      query: query,
      select: select,
      opts: opts}
  end

  defp singly_cursor(conn, coll, query, select, opts) do
    %Mongo.SinglyCursor{
      conn: conn,
      coll: coll,
      query: query,
      select: select,
      opts: opts}
  end

  defp aggregation_cursor(conn, coll, query, select, opts) do
    %Mongo.AggregationCursor{
      conn: conn,
      coll: coll,
      query: query,
      select: select,
      opts: opts}
  end

  defp filter_nils(keyword) when is_list(keyword) do
    Enum.reject(keyword, fn {_key, value} -> is_nil(value) end)
  end

  defp filter_nils(map) when is_map(map) do
    Enum.reject(map, fn {_key, value} -> is_nil(value) end)
    |> Enum.into(%{})
  end

  defp normalize_doc(doc) do
    Enum.reduce(doc, {:unknown, []}, fn
      {key, _value}, {:binary, _acc} when is_atom(key) ->
        invalid_doc(doc)

      {key, _value}, {:atom, _acc} when is_binary(key) ->
        invalid_doc(doc)

      {key, value}, {_, acc} when is_atom(key) ->
        {:atom, [{key, value}|acc]}

      {key, value}, {_, acc} when is_binary(key) ->
        {:binary, [{key, value}|acc]}
    end)
    |> elem(1)
    |> Enum.reverse
  end

  defp invalid_doc(doc) do
    message = "invalid document containing atom and string keys: #{inspect doc}"
    raise ArgumentError, message
  end

  defp cursor_type(nil),
    do: []
  defp cursor_type(:tailable),
    do: [tailable_cursor: true]
  defp cursor_type(:tailable_await),
    do: [tailable_cursor: true, await_data: true]

  defp assert_single_doc!(doc) when is_map(doc), do: :ok
  defp assert_single_doc!([]), do: :ok
  defp assert_single_doc!([{_, _} | _]), do: :ok
  defp assert_single_doc!(other) do
    raise ArgumentError, "expected single document, got: #{inspect other}"
  end

  defp assert_many_docs!([first | _]) when not is_tuple(first), do: :ok
  defp assert_many_docs!(other) do
    raise ArgumentError, "expected list of documents, got: #{inspect other}"
  end

  defp defaults(opts) do
    Keyword.put_new(opts, :timeout, @timeout)
  end

  defp get_last_error(:ok) do
    :ok
  end
  defp get_last_error(op_reply(docs: [%{"ok" => 1.0, "err" => nil} = doc])) do
    {:ok, doc}
  end
  defp get_last_error(op_reply(docs: [%{"ok" => 1.0, "err" => message, "code" => code}])) do
    # If a batch insert (OP_INSERT) fails some documents may still have been
    # inserted, but mongo always returns {n: 0}
    # When we support the 2.6 bulk write API we will get number of inserted
    # documents and should change the return value to be something like:
    # {:error, %WriteResult{}, %Error{}}
    {:error, Mongo.Error.exception(message: message, code: code)}
  end
  defp get_last_error(op_reply(docs: [%{"ok" => 0.0, "errmsg" => message, "code" => code}])) do
    {:error, Mongo.Error.exception(message: message, code: code)}
  end

  defp assign_ids(doc) when is_map(doc) do
    [assign_id(doc)]
    |> Enum.unzip
  end

  defp assign_ids([{_, _} | _] = doc) do
    [assign_id(doc)]
    |> Enum.unzip
  end

  defp assign_ids(list) when is_list(list) do
    Enum.map(list, &assign_id/1)
    |> Enum.unzip
  end
  defp assign_id(%{_id: id} = map) when id != nil,
    do: {id, map}
  defp assign_id(%{"_id" => id} = map) when id != nil,
    do: {id, map}

  defp assign_id([{_, _} | _] = keyword) do
    case Keyword.take(keyword, [:_id, "_id"]) do
      [{_key, id} | _] when id != nil ->
        {id, keyword}
      [] ->
        add_id(keyword)
    end
  end

  defp assign_id(map) when is_map(map) do
    map |> Map.to_list |> add_id
  end

  defp add_id(doc) do
    id = Mongo.IdServer.new
    {id, add_id(doc, id)}
  end
  defp add_id([{key, _}|_] = list, id) when is_atom(key) do
    [{:_id, id}|list]
  end
  defp add_id([{key, _}|_] = list, id) when is_binary(key) do
    [{"_id", id}|list]
  end
  defp add_id([], id) do
    # Why are you inserting empty documents =(
    [{"_id", id}]
  end

  defp index_map([], _ix, map),
    do: map
  defp index_map([elem|list], ix, map),
    do: index_map(list, ix+1, Map.put(map, ix, elem))

  defp maybe_failure(op_reply(flags: flags, docs: [%{"$err" => reason, "code" => code}]))
    when (@reply_query_failure &&& flags) != 0,
    do: {:error, Mongo.Error.exception(message: reason, code: code)}
  defp maybe_failure(op_reply(flags: flags))
    when (@reply_cursor_not_found &&& flags) != 0,
    do: {:error, Mongo.Error.exception(message: "cursor not found")}
  defp maybe_failure(_reply),
    do: :ok
end
