defmodule Mongo.Test do
  use MongoTest.Case, async: true

  setup_all do
    assert {:ok, pid} = Mongo.start_link(database: "mongodb_test")
    {:ok, [pid: pid]}
  end

  test "object_id" do
    assert %BSON.ObjectId{value: <<_::96>>} = Mongo.object_id
  end

  test "command", c do
    assert {:ok, %{"ok" => 1.0}} = Mongo.command(c.pid, %{ping: true})
    assert {:error, %Mongo.Error{}} =
      Mongo.command(c.pid, %{ drop: "unexisting-database" })
  end

  test "command!", c do
    assert %{"ok" => 1.0} = Mongo.command!(c.pid, %{ping: true})
    assert_raise Mongo.Error, fn ->
      Mongo.command!(c.pid, %{ drop: "unexisting-database" })
    end
  end

  test "aggregate", c do
    coll = unique_name()

    assert {:ok, _} = Mongo.insert_one(c.pid, coll, %{foo: 42})
    assert {:ok, _} = Mongo.insert_one(c.pid, coll, %{foo: 43})
    assert {:ok, _} = Mongo.insert_one(c.pid, coll, %{foo: 44})
    assert {:ok, _} = Mongo.insert_one(c.pid, coll, %{foo: 45})

    assert [%{"foo" => 42}, %{"foo" => 43}, %{"foo" => 44}, %{"foo" => 45}] =
           Mongo.aggregate(c.pid, coll, []) |> Enum.to_list

    assert []               = Mongo.aggregate(c.pid, coll, []) |> Enum.take(0)
    assert []               = Mongo.aggregate(c.pid, coll, []) |> Enum.drop(4)
    assert [%{"foo" => 42}] = Mongo.aggregate(c.pid, coll, []) |> Enum.take(1)
    assert [%{"foo" => 45}] = Mongo.aggregate(c.pid, coll, []) |> Enum.drop(3)

    assert []               = Mongo.aggregate(c.pid, coll, [], use_cursor: false) |> Enum.take(0)
    assert []               = Mongo.aggregate(c.pid, coll, [], use_cursor: false) |> Enum.drop(4)
    assert [%{"foo" => 42}] = Mongo.aggregate(c.pid, coll, [], use_cursor: false) |> Enum.take(1)
    assert [%{"foo" => 45}] = Mongo.aggregate(c.pid, coll, [], use_cursor: false) |> Enum.drop(3)

    assert []               = Mongo.aggregate(c.pid, coll, [], batch_size: 1) |> Enum.take(0)
    assert []               = Mongo.aggregate(c.pid, coll, [], batch_size: 1) |> Enum.drop(4)
    assert [%{"foo" => 42}] = Mongo.aggregate(c.pid, coll, [], batch_size: 1) |> Enum.take(1)
    assert [%{"foo" => 45}] = Mongo.aggregate(c.pid, coll, [], batch_size: 1) |> Enum.drop(3)
  end

  test "count", c do
    coll = unique_name()

    assert {:ok, 0} = Mongo.count(c.pid, coll, [])

    assert {:ok, _} = Mongo.insert_one(c.pid, coll, %{foo: 42})
    assert {:ok, _} = Mongo.insert_one(c.pid, coll, %{foo: 43})

    assert {:ok, 2} = Mongo.count(c.pid, coll, %{})
    assert {:ok, 1} = Mongo.count(c.pid, coll, %{foo: 42})
  end

  test "count!", c do
    coll = unique_name()

    assert 0 = Mongo.count!(c.pid, coll, %{foo: 43})
  end

  test "distinct", c do
    coll = unique_name()

    assert {:ok, []} = Mongo.distinct(c.pid, coll, "foo", %{})

    assert {:ok, _} = Mongo.insert_one(c.pid, coll, %{foo: 42})
    assert {:ok, _} = Mongo.insert_one(c.pid, coll, %{foo: 42})
    assert {:ok, _} = Mongo.insert_one(c.pid, coll, %{foo: 43})

    assert {:ok, [42, 43]} = Mongo.distinct(c.pid, coll, "foo", %{})
    assert {:ok, [42]}     = Mongo.distinct(c.pid, coll, "foo", %{foo: 42})
  end

  test "distinct!", c do
    coll = unique_name()

    assert [] = Mongo.distinct!(c.pid, coll, "foo", %{})
  end

  test "find", c do
    coll = unique_name()

    assert [] = Mongo.find(c.pid, coll, %{}) |> Enum.to_list

    assert {:ok, _} = Mongo.insert_one(c.pid, coll, %{foo: 42, bar: 1})
    assert {:ok, _} = Mongo.insert_one(c.pid, coll, %{foo: 43, bar: 2})
    assert {:ok, _} = Mongo.insert_one(c.pid, coll, %{foo: 44, bar: 3})

    assert [%{"foo" => 42}, %{"foo" => 43}, %{"foo" => 44}] =
           Mongo.find(c.pid, coll, %{}) |> Enum.to_list

    # Mongo is weird with batch_size=1
    assert [%{"foo" => 42}] = Mongo.find(c.pid, coll, %{}, batch_size: 1) |> Enum.to_list

    assert [%{"foo" => 42}, %{"foo" => 43}, %{"foo" => 44}] =
           Mongo.find(c.pid, coll, %{}, batch_size: 2) |> Enum.to_list

    assert [%{"foo" => 42}, %{"foo" => 43}] =
           Mongo.find(c.pid, coll, %{}, limit: 2) |> Enum.to_list

    assert [%{"foo" => 42}, %{"foo" => 43}] =
           Mongo.find(c.pid, coll, %{}, batch_size: 2, limit: 2) |> Enum.to_list

    assert [%{"foo" => 42}] =
           Mongo.find(c.pid, coll, %{bar: 1}) |> Enum.to_list

    assert [%{"bar" => 1}, %{"bar" => 2}, %{"bar" => 3}] =
           Mongo.find(c.pid, coll, %{}, projection: %{bar: 1}) |> Enum.to_list

    assert [%{"bar" => 1}] =
           Mongo.find(c.pid, coll, %{"$query": %{foo: 42}}, projection: %{bar: 1}) |> Enum.to_list

    assert [%{"foo" => 44}, %{"foo" => 43}] =
      Mongo.find(c.pid, coll, %{}, sort: [foo: -1], batch_size: 2, limit: 2) |> Enum.to_list
  end

  @tag :find_and_modify
  test "find_and_modify", c do
    coll = unique_name()

    assert {:ok, _} = Mongo.insert_one(c.pid, coll, %{foo: 42, bar: 1})

    # test default
    assert {:ok, %{"lastErrorObject" => last_error_object, "value" => value, "ok" => 1.0}} =
      Mongo.find_and_modify(c.pid, coll, %{"foo" => 42}, %{"$set" => %{bar: 2}})
    assert %{"n" => 1, "updatedExisting" => true} = last_error_object
    assert %{"_id" =>  _, "foo" => 42, "bar" => 1 } = value

    # Test opts[:new] = true
    assert {:ok, %{"lastErrorObject" => last_error_object, "value" => value, "ok" => 1.0}} =
      Mongo.find_and_modify(c.pid, coll, %{"foo" => 42}, %{"$set" => %{bar: 2}}, [new: true])
    assert %{"n" => 1, "updatedExisting" => true} = last_error_object
    assert %{"_id" =>  _, "foo" => 42, "bar" => 2 } = value, "Response doc includes new value"

    # Test opts[:fields]
    assert {:ok, %{"lastErrorObject" => last_error_object, "value" => value, "ok" => 1.0}} =
      Mongo.find_and_modify(c.pid, coll, %{"foo" => 42}, %{"$set" => %{bar: 2}}, [fields: %{"bar" => 1}])
    assert %{"n" => 1, "updatedExisting" => true} = last_error_object
    assert %{"_id" =>  _, "bar" => 2} = value, "Response doc includes selected fields"
    assert !Map.has_key?(value, "foo"), "Response doc does not include \"foo\""

    # Test opts[:upsert] = true
    assert {:ok, %{"lastErrorObject" => last_error_object, "value" => value, "ok" => 1.0}} =
      Mongo.find_and_modify(c.pid, coll, %{"foo" => 1}, %{"$set" => %{bar: 2}}, [upsert: true])
    assert %{"n" => 1, "updatedExisting" => false} = last_error_object, "Upserted"
    assert value == nil, "Does not return a document"

    # Test opts[:upsert] = true && opts[:new] = true
    assert {:ok, %{"lastErrorObject" => last_error_object, "value" => value, "ok" => 1.0}} =
      Mongo.find_and_modify(c.pid, coll, %{"foo" => 2}, %{"$set" => %{bar: 2}}, [upsert: true, new: true])
    assert %{"n" => 1, "updatedExisting" => false} = last_error_object, "Upserted"
    assert %{"_id" =>  _, "foo" => 2, "bar" => 2} = value, "Returned upserted document"

    # Test opts[:remove] = true
    assert {:ok, %{"lastErrorObject" => last_error_object, "value" => value, "ok" => 1.0}} =
      Mongo.find_and_modify(c.pid, coll, %{"foo" => 42}, %{}, [remove: true])
    assert %{"n" => 1} = last_error_object, "Removed"
    assert %{"_id" => _, "foo" => 42, "bar" => _} = value
    assert {:ok, 0} = Mongo.count(c.pid, coll, %{"foo" => 42}), "Removed the document"
  end

  test "insert_one", c do
    coll = unique_name()

    assert_raise ArgumentError, fn ->
      Mongo.insert_one(c.pid, coll, [%{foo: 42, bar: 1}])
    end

    assert {:ok, result} = Mongo.insert_one(c.pid, coll, %{foo: 42})
    assert %Mongo.InsertOneResult{inserted_id: id} = result

    assert [%{"_id" => ^id, "foo" => 42}] = Mongo.find(c.pid, coll, %{_id: id}) |> Enum.to_list

    assert :ok = Mongo.insert_one(c.pid, coll, %{}, w: 0)
  end

  test "insert_one!", c do
    coll = unique_name()

    assert %Mongo.InsertOneResult{} = Mongo.insert_one!(c.pid, coll, %{"_id" => 1})
    assert nil == Mongo.insert_one!(c.pid, coll, %{}, w: 0)

    assert_raise Mongo.Error, fn ->
      Mongo.insert_one!(c.pid, coll, %{_id: 1})
    end
  end

  test "insert_many", c do
    coll = unique_name()

    assert_raise ArgumentError, fn ->
      Mongo.insert_many(c.pid, coll, %{foo: 42, bar: 1})
    end

    assert {:ok, result} = Mongo.insert_many(c.pid, coll, [%{foo: 42}, %{foo: 43}])
    assert %Mongo.InsertManyResult{inserted_ids: %{0 => id0, 1 => id1}} = result

    assert [%{"_id" => ^id0, "foo" => 42}] = Mongo.find(c.pid, coll, %{_id: id0}) |> Enum.to_list
    assert [%{"_id" => ^id1, "foo" => 43}] = Mongo.find(c.pid, coll, %{_id: id1}) |> Enum.to_list

    assert :ok = Mongo.insert_many(c.pid, coll, [%{}], w: 0)
  end

  test "insert_many!", c do
    coll = unique_name()

    docs = [%{foo: 42}, %{foo: 43}]
    assert %Mongo.InsertManyResult{} = Mongo.insert_many!(c.pid, coll, docs)

    assert nil == Mongo.insert_many!(c.pid, coll, [%{}], w: 0)

    assert_raise Mongo.Error, fn ->
      Mongo.insert_many!(c.pid, coll, [%{_id: 1}, %{_id: 1}])
    end
  end

  test "delete_one", c do
    coll = unique_name()

    assert {:ok, _} = Mongo.insert_many(c.pid, coll, [%{foo: 42}, %{foo: 42}, %{foo: 43}])

    assert {:ok, %Mongo.DeleteResult{deleted_count: 1}} = Mongo.delete_one(c.pid, coll, %{foo: 42})
    assert [%{"foo" => 42}] = Mongo.find(c.pid, coll, %{foo: 42}) |> Enum.to_list

    assert {:ok, %Mongo.DeleteResult{deleted_count: 1}} = Mongo.delete_one(c.pid, coll, %{foo: 42})
    assert [] = Mongo.find(c.pid, coll, %{foo: 42}) |> Enum.to_list

    assert {:ok, %Mongo.DeleteResult{deleted_count: 0}} = Mongo.delete_one(c.pid, coll, %{foo: 42})
    assert [%{"foo" => 43}] = Mongo.find(c.pid, coll, %{foo: 43}) |> Enum.to_list
  end

  test "delete_one!", c do
    coll = unique_name()

    assert %Mongo.DeleteResult{deleted_count: 0} = Mongo.delete_one!(c.pid, coll, %{foo: 42})

    assert nil == Mongo.delete_one!(c.pid, coll, %{}, w: 0)
  end

  test "delete_many", c do
    coll = unique_name()

    assert {:ok, _} = Mongo.insert_many(c.pid, coll, [%{foo: 42}, %{foo: 42}, %{foo: 43}])

    assert {:ok, %Mongo.DeleteResult{deleted_count: 2}} = Mongo.delete_many(c.pid, coll, %{foo: 42})
    assert [] = Mongo.find(c.pid, coll, %{foo: 42}) |> Enum.to_list

    assert {:ok, %Mongo.DeleteResult{deleted_count: 0}} = Mongo.delete_one(c.pid, coll, %{foo: 42})
    assert [%{"foo" => 43}] = Mongo.find(c.pid, coll, %{foo: 43}) |> Enum.to_list
  end

  test "delete_many!", c do
    coll = unique_name()

    assert %Mongo.DeleteResult{deleted_count: 0} = Mongo.delete_many!(c.pid, coll, %{foo: 42})

    assert nil == Mongo.delete_many!(c.pid, coll, %{}, w: 0)
  end

  test "replace_one", c do
    coll = unique_name()

    assert_raise ArgumentError, fn ->
      Mongo.replace_one(c.pid, coll, %{foo: 42}, %{"$set": %{foo: 0}})
    end

    assert {:ok, _} = Mongo.insert_many(c.pid, coll, [%{foo: 42}, %{foo: 42}, %{foo: 43}])

    assert {:ok, %Mongo.UpdateResult{matched_count: 1, modified_count: 1, upserted_id: nil}} =
           Mongo.replace_one(c.pid, coll, %{foo: 42}, %{foo: 0})

    assert [_] = Mongo.find(c.pid, coll, %{foo: 0}) |> Enum.to_list
    assert [_] = Mongo.find(c.pid, coll, %{foo: 42}) |> Enum.to_list

    assert {:ok, %Mongo.UpdateResult{matched_count: 0, modified_count: 1, upserted_id: id}} =
           Mongo.replace_one(c.pid, coll, %{foo: 50}, %{foo: 0}, upsert: true)
    assert [_] = Mongo.find(c.pid, coll, %{_id: id}) |> Enum.to_list

    assert {:ok, %Mongo.UpdateResult{matched_count: 1, modified_count: 1, upserted_id: nil}} =
           Mongo.replace_one(c.pid, coll, %{foo: 43}, %{foo: 1}, upsert: true)
    assert [] = Mongo.find(c.pid, coll, %{foo: 43}) |> Enum.to_list
    assert [_] = Mongo.find(c.pid, coll, %{foo: 1}) |> Enum.to_list
  end

  test "replace_one!", c do
    coll = unique_name()

    assert {:ok, _} = Mongo.insert_many(c.pid, coll, [%{foo: 42}, %{_id: 1}])

    assert %Mongo.UpdateResult{matched_count: 0, modified_count: 0, upserted_id: nil} =
      Mongo.replace_one!(c.pid, coll, %{foo: 43}, %{foo: 0})

    assert nil == Mongo.replace_one!(c.pid, coll, %{foo: 45}, %{foo: 0}, w: 0)

    assert_raise Mongo.Error, fn ->
      Mongo.replace_one!(c.pid, coll, %{foo: 42}, %{_id: 1})
    end
  end

  test "update_one", c do
    coll = unique_name()

    assert_raise ArgumentError, fn ->
      Mongo.update_one(c.pid, coll, %{foo: 42}, %{foo: 0})
    end

    assert {:ok, _} = Mongo.insert_many(c.pid, coll, [%{foo: 42}, %{foo: 42}, %{foo: 43}])

    assert {:ok, %Mongo.UpdateResult{matched_count: 1, modified_count: 1, upserted_id: nil}} =
           Mongo.update_one(c.pid, coll, %{foo: 42}, %{"$set": %{foo: 0}})

    assert [_] = Mongo.find(c.pid, coll, %{foo: 0}) |> Enum.to_list
    assert [_] = Mongo.find(c.pid, coll, %{foo: 42}) |> Enum.to_list

    assert {:ok, %Mongo.UpdateResult{matched_count: 0, modified_count: 1, upserted_id: id}} =
           Mongo.update_one(c.pid, coll, %{foo: 50}, %{"$set": %{foo: 0}}, upsert: true)
    assert [_] = Mongo.find(c.pid, coll, %{_id: id}) |> Enum.to_list

    assert {:ok, %Mongo.UpdateResult{matched_count: 1, modified_count: 1, upserted_id: nil}} =
           Mongo.update_one(c.pid, coll, %{foo: 43}, %{"$set": %{foo: 1}}, upsert: true)
    assert [] = Mongo.find(c.pid, coll, %{foo: 43}) |> Enum.to_list
    assert [_] = Mongo.find(c.pid, coll, %{foo: 1}) |> Enum.to_list
  end

  test "update_one!", c do
    coll = unique_name()

    assert {:ok, _} = Mongo.insert_many(c.pid, coll, [%{foo: 42}, %{_id: 1}])

    assert %Mongo.UpdateResult{matched_count: 1, modified_count: 1, upserted_id: nil} =
      Mongo.update_one!(c.pid, coll, %{foo: 42}, %{"$set": %{foo: 0}})

    assert nil == Mongo.update_one!(c.pid, coll, %{foo: 42}, %{}, w: 0)

    assert_raise Mongo.Error, fn ->
      Mongo.update_one!(c.pid, coll, %{foo: 0}, %{"$set": %{_id: 0}})
    end
  end

  test "update_many", c do
    coll = unique_name()

    assert_raise ArgumentError, fn ->
      Mongo.update_many(c.pid, coll, %{foo: 42}, %{foo: 0})
    end

    assert {:ok, _} = Mongo.insert_many(c.pid, coll, [%{foo: 42}, %{foo: 42}, %{foo: 43}])

    assert {:ok, %Mongo.UpdateResult{matched_count: 2, modified_count: 2, upserted_id: nil}} =
           Mongo.update_many(c.pid, coll, %{foo: 42}, %{"$set": %{foo: 0}})

    assert [_, _] = Mongo.find(c.pid, coll, %{foo: 0}) |> Enum.to_list
    assert [] = Mongo.find(c.pid, coll, %{foo: 42}) |> Enum.to_list

    assert {:ok, %Mongo.UpdateResult{matched_count: 0, modified_count: 1, upserted_id: id}} =
           Mongo.update_many(c.pid, coll, %{foo: 50}, %{"$set": %{foo: 0}}, upsert: true)
    assert [_] = Mongo.find(c.pid, coll, %{_id: id}) |> Enum.to_list

    assert {:ok, %Mongo.UpdateResult{matched_count: 1, modified_count: 1, upserted_id: nil}} =
           Mongo.update_many(c.pid, coll, %{foo: 43}, %{"$set": %{foo: 1}}, upsert: true)
    assert [] = Mongo.find(c.pid, coll, %{foo: 43}) |> Enum.to_list
    assert [_] = Mongo.find(c.pid, coll, %{foo: 1}) |> Enum.to_list
  end

  test "update_many!", c do
    coll = unique_name()

    assert {:ok, _} = Mongo.insert_many(c.pid, coll, [%{foo: 42}, %{foo: 42}, %{_id: 1}])

    assert %Mongo.UpdateResult{matched_count: 2, modified_count: 2, upserted_id: nil} =
      Mongo.update_many!(c.pid, coll, %{foo: 42}, %{"$set": %{foo: 0}})

    assert nil == Mongo.update_many!(c.pid, coll, %{foo: 0}, %{}, w: 0)

    assert_raise Mongo.Error, fn ->
      Mongo.update_many!(c.pid, coll, %{foo: 0}, %{"$set": %{_id: 1}})
    end
  end

  # TODO
  # test "logging", c do
  #   coll = unique_name()
  #
  #   Mongo.find(LoggingPool, coll, %{}, log: false) |> Enum.to_list
  #   refute Process.get(:last_log)
  #
  #   Mongo.find(LoggingPool, coll, %{}) |> Enum.to_list
  #   assert Process.get(:last_log) == {:find, [coll, %{}, nil, [batch_size: 1000]]}
  # end

  # issue #19
  test "correctly pass options to cursor", c do
    assert %Mongo.Cursor{coll: "coll", opts: [no_cursor_timeout: true, skip: 10]} =
           Mongo.find(c.pid, "coll", %{}, skip: 10, cursor_timeout: false)
  end
end
