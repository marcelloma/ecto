defmodule Ecto.AssociationTest do
  use ExUnit.Case, async: true

  import Ecto.Query

  alias Ecto.Association.BelongsTo
  alias Ecto.Association.Has
  alias Ecto.Query.Planner
  alias Ecto.TestRepo

  defmodule Parent do
    use Ecto.Schema

    schema "parents" do
      field :tenant_id, :string

      has_many :children, Ecto.AssociationTest.Child,
        references: [:tenant_id, :id],
        foreign_key: [:tenant_id, :parent_id]

      has_one :child, Ecto.AssociationTest.Child,
        references: [:tenant_id, :id],
        foreign_key: [:tenant_id, :parent_id]

      has_many :scoped_children, {"scoped_children", Ecto.AssociationTest.Child},
        references: [:tenant_id, :id],
        foreign_key: [:tenant_id, :parent_id]
    end
  end

  test "validates every related field in a composite has_many" do
    assoc = Parent.__schema__(:association, :children)

    assert Has.after_verify_validation(assoc) == :ok

    assert Has.after_verify_validation(%{assoc | related_key: [:tenant_id, :missing]}) ==
             {:error,
              "associated schema #{inspect(Ecto.AssociationTest.Child)} does not have field `missing`"}
  end

  test "validates every related field in a composite has_one" do
    assoc = Parent.__schema__(:association, :child)

    assert assoc.cardinality == :one
    assert assoc.owner_key == [:tenant_id, :id]
    assert assoc.related_key == [:tenant_id, :parent_id]
    assert Has.after_verify_validation(assoc) == :ok

    assert Has.after_verify_validation(%{assoc | related_key: [:tenant_id, :missing]}) ==
             {:error,
              "associated schema #{inspect(Ecto.AssociationTest.Child)} does not have field `missing`"}
  end

  test "validates a composite has_many with a source and schema tuple" do
    assoc = Parent.__schema__(:association, :scoped_children)

    assert Has.after_verify_validation(assoc) == :ok

    assert Has.after_verify_validation(%{assoc | related_key: [:tenant_id, :missing]}) ==
             {:error,
              "associated schema #{inspect(Ecto.AssociationTest.Child)} does not have field `missing`"}
  end

  test "joins a composite has_many on both keys" do
    query = from(p in Parent, join: c in assoc(p, :children), select: c)
    {planned, _, _} = Planner.plan(query, :all, Ecto.TestAdapter)

    [join] = planned.joins
    on = Macro.to_string(join.on.expr)

    assert on =~ "&0.tenant_id()"
    assert on =~ "&1.tenant_id()"
    assert on =~ "&0.id()"
    assert on =~ "&1.parent_id()"
    assert on =~ "and"
  end

  test "joins a composite has_one on both keys" do
    query = from(p in Parent, join: c in assoc(p, :child), select: c)
    {planned, _, _} = Planner.plan(query, :all, Ecto.TestAdapter)

    [join] = planned.joins
    on = Macro.to_string(join.on.expr)

    assert on =~ "&0.tenant_id()"
    assert on =~ "&1.tenant_id()"
    assert on =~ "&0.id()"
    assert on =~ "&1.parent_id()"
    assert on =~ "and"
  end

  test "builds a composite has_many child with every owner key" do
    child =
      Ecto.build_assoc(%Parent{tenant_id: "east", id: 5}, :children,
        tenant_id: "west",
        parent_id: 2
      )

    assert child.__struct__ == Ecto.AssociationTest.Child
    assert %{tenant_id: "east", parent_id: 5} = child
  end

  test "builds a composite has_one child with every owner key" do
    child =
      Ecto.build_assoc(%Parent{tenant_id: "east", id: 5}, :child,
        tenant_id: "west",
        parent_id: 2
      )

    assert child.__struct__ == Ecto.AssociationTest.Child
    assert %{tenant_id: "east", parent_id: 5} = child
  end

  defmodule Child do
    use Ecto.Schema

    schema "children" do
      field :tenant_id, :string
      field :parent_id, :id

      belongs_to :parent, Parent,
        foreign_key: [:tenant_id, :parent_id],
        references: [:tenant_id, :id],
        define_field: false

      belongs_to :scoped_parent, {"scoped_parents", Parent},
        foreign_key: [:tenant_id, :parent_id],
        references: [:tenant_id, :id],
        define_field: false
    end
  end

  defmodule ThreeKeyChild do
    use Ecto.Schema

    schema "three_key_children" do
      field :state, Ecto.Enum, values: [:loaded]
      field :tenant_id, :integer
      field :parent_id, :integer
    end
  end

  defmodule ThreeKeyParent do
    use Ecto.Schema

    schema "three_key_parents" do
      field :state, Ecto.Enum, values: [:loaded]
      field :tenant_id, :integer

      has_many :children, Ecto.AssociationTest.ThreeKeyChild,
        references: [:state, :tenant_id, :id],
        foreign_key: [:state, :tenant_id, :parent_id]
    end
  end

  test "preloads composite has_many with each key ordered before the custom order" do
    Process.put(:test_repo_all_results, {0, []})

    for {parent, keys} <- [
          {%Parent{id: 1, tenant_id: "east"}, [:tenant_id, :parent_id]},
          {%ThreeKeyParent{id: 1, state: :loaded, tenant_id: 7}, [:state, :tenant_id, :parent_id]}
        ] do
      related = parent.__struct__.__schema__(:association, :children).related
      query = from(c in related, order_by: [desc: c.id])

      assert %{children: []} = TestRepo.preload(parent, children: query)
      assert_receive {:all, query}

      assert [%{expr: key_order}, %{expr: [desc: _]}] = query.order_bys

      assert Enum.map(key_order, fn
               {:asc, {{:., _, [{:&, _, [0]}, key]}, _, []}} -> key
             end) == keys
    end
  end

  test "warns and preserves a loaded composite has_many with an incomplete owner key" do
    child = %Child{id: 2, parent_id: 1}
    parent = %Parent{id: 1, children: [child]}

    log =
      ExUnit.CaptureLog.capture_log(fn ->
        assert TestRepo.preload(parent, :children) == parent
      end)

    assert log =~ "association `children`"
    assert log =~ "one or more of its association key fields `[:tenant_id, :id]` are nil"
    assert log =~ "one or more of these fields were not selected in the query"
  end

  test "warns and preserves a loaded composite belongs_to with an incomplete owner key" do
    parent = %Parent{id: 1, tenant_id: "east"}
    child = %Child{id: 2, parent_id: 1, parent: parent}

    log =
      ExUnit.CaptureLog.capture_log(fn ->
        assert TestRepo.preload(child, :parent) == child
      end)

    assert log =~ "association `parent`"
    assert log =~ "one or more of its association key fields `[:tenant_id, :parent_id]` are nil"
    assert log =~ "one or more of these fields were not selected in the query"
  end

  test "preloads three-key has_many values without confusing keys with loaded markers" do
    loaded_child = %ThreeKeyChild{id: 10, state: :loaded, tenant_id: 7, parent_id: 1}
    fetched_child = %ThreeKeyChild{id: 11, state: :loaded, tenant_id: 7, parent_id: 2}
    loaded_parent = %ThreeKeyParent{id: 1, state: :loaded, tenant_id: 7, children: [loaded_child]}
    fetched_parent = %ThreeKeyParent{id: 2, state: :loaded, tenant_id: 7}

    [loaded, fetched] =
      TestRepo.preload([loaded_parent, fetched_parent],
        children: fn ids ->
          assert ids == [{:loaded, 7, 2}]
          [fetched_child]
        end
      )

    assert loaded.children == [loaded_child]
    assert fetched.children == [fetched_child]
  end

  defmodule ChainOrganization do
    use Ecto.Schema

    schema "chain_organizations" do
      field :active, :boolean
    end
  end

  defmodule ChainParent do
    use Ecto.Schema

    schema "chain_parents" do
      field :tenant_id, :string
      belongs_to :organization, ChainOrganization, where: [active: true]
    end
  end

  defmodule ChainChild do
    use Ecto.Schema

    schema "chain_children" do
      field :tenant_id, :string
      field :parent_id, :id

      belongs_to :parent, ChainParent,
        foreign_key: [:tenant_id, :parent_id],
        references: [:tenant_id, :id],
        define_field: false

      has_one :organization, through: [:parent, :organization]
    end
  end

  defmodule ChainGrandchild do
    use Ecto.Schema

    schema "chain_grandchildren" do
      belongs_to :child, ChainChild
      has_one :organization, through: [:child, :parent, :organization]
    end
  end

  test "preserves the scalar association key warning" do
    parent = %ChainParent{organization: %ChainOrganization{id: 1}}

    log =
      ExUnit.CaptureLog.capture_log([format: "$message"], fn ->
        assert TestRepo.preload(parent, :organization) == parent
      end)

    assert log == """
           association `organization` for `#{inspect(ChainParent)}` has a loaded value but \
           its association key `organization_id` is nil. This usually means one of:

             * `organization_id` was not selected in a query
             * the struct was set with default values for `organization` which now you want to override

           If this is intentional, set force: true to disable this warning
           """
  end

  test "validates every field in a composite belongs_to" do
    assoc = Child.__schema__(:association, :parent)

    assert BelongsTo.after_verify_validation(assoc) == :ok

    assert BelongsTo.after_verify_validation(%{assoc | owner_key: [:missing, :parent_id]}) ==
             {:error, "schema #{inspect(Child)} does not have field `missing`"}

    assert BelongsTo.after_verify_validation(%{assoc | owner_key: [:tenant_id, :missing]}) ==
             {:error, "schema #{inspect(Child)} does not have field `missing`"}

    assert BelongsTo.after_verify_validation(%{assoc | related_key: [:missing, :id]}) ==
             {:error, "associated schema #{inspect(Parent)} does not have field `missing`"}

    assert BelongsTo.after_verify_validation(%{assoc | related_key: [:tenant_id, :missing]}) ==
             {:error, "associated schema #{inspect(Parent)} does not have field `missing`"}
  end

  test "validates composite associations using a source and schema tuple" do
    assoc = Child.__schema__(:association, :scoped_parent)

    assert BelongsTo.after_verify_validation(assoc) == :ok

    assert BelongsTo.after_verify_validation(%{assoc | related_key: [:tenant_id, :missing]}) ==
             {:error, "associated schema #{inspect(Parent)} does not have field `missing`"}
  end

  test "joins a composite belongs_to from the query macro" do
    query = from(c in Child, join: p in assoc(c, :parent), select: p)
    {planned, _, _} = Planner.plan(query, :all, Ecto.TestAdapter)

    [join] = planned.joins
    on = Macro.to_string(join.on.expr)

    assert on =~ "&0.tenant_id()"
    assert on =~ "&1.tenant_id()"
    assert on =~ "&0.parent_id()"
    assert on =~ "&1.id()"
    assert on =~ "and"
  end

  test "joins a through association across a composite belongs_to" do
    query = from(c in ChainChild, join: o in assoc(c, :organization), select: o)
    {planned, _, _} = Planner.plan(query, :all, Ecto.TestAdapter)

    [parent_join, organization_join] = planned.joins
    parent_on = Macro.to_string(parent_join.on.expr)
    organization_on = Macro.to_string(organization_join.on.expr)

    assert parent_on =~ "&0.tenant_id()"
    assert parent_on =~ "&2.tenant_id()"
    assert parent_on =~ "&0.parent_id()"
    assert parent_on =~ "&2.id()"
    assert parent_on =~ "and"
    assert organization_on =~ "organization_id"
    assert organization_on =~ "active"
  end

  test "filters a chained association by a complete composite owner key" do
    query = Ecto.assoc(%ChainChild{tenant_id: "east", parent_id: 1}, [:parent, :organization])
    {planned, params, _} = Planner.plan(query, :all, Ecto.TestAdapter)

    [filter] = planned.wheres
    condition = Macro.to_string(filter.expr)

    assert condition =~ "&1.tenant_id()"
    assert condition =~ "&1.id()"
    assert condition =~ "and"
    assert Enum.map(params, &elem(&1, 0)) == ["east", 1, true]
  end

  test "joins a composite hop after the first association in a chain" do
    query = Ecto.assoc(%ChainGrandchild{child_id: 5}, [:child, :parent, :organization])
    {planned, params, _} = Planner.plan(query, :all, Ecto.TestAdapter)

    [_, child_join] = planned.joins
    on = Macro.to_string(child_join.on.expr)

    assert on =~ "&1.tenant_id()"
    assert on =~ "&2.tenant_id()"
    assert on =~ "&1.id()"
    assert on =~ "&2.parent_id()"
    assert on =~ "and"
    assert Enum.map(params, &elem(&1, 0)) == [5, true]
  end

  test "queries a declared through association with a composite first hop" do
    query = Ecto.assoc(%ChainChild{tenant_id: "east", parent_id: 1}, :organization)
    {planned, params, _} = Planner.plan(query, :all, Ecto.TestAdapter)

    assert length(planned.joins) == 1
    assert Macro.to_string(hd(planned.wheres).expr) =~ "&1.tenant_id()"
    assert Enum.map(params, &elem(&1, 0)) == ["east", 1, true]
  end

  test "filters a chained association by exact composite keys for multiple owners" do
    owners = [
      %ChainChild{tenant_id: "east", parent_id: 1},
      %ChainChild{tenant_id: "west", parent_id: 2},
      %ChainChild{tenant_id: "east", parent_id: 1},
      %ChainChild{tenant_id: nil, parent_id: 3}
    ]

    query = Ecto.assoc(owners, [:parent, :organization])
    {planned, params, cache_key} = Planner.plan(query, :all, Ecto.TestAdapter)
    [filter] = planned.wheres
    condition = Macro.to_string(filter.expr)

    assert condition =~ " or "
    assert condition =~ "&1.tenant_id()"
    assert condition =~ "&1.id()"
    assert length(String.split(condition, " and ")) == 3
    assert Enum.map(params, &elem(&1, 0)) == ["east", 1, "west", 2, true]
    assert cache_key != :nocache

    other_owners = [
      %ChainChild{tenant_id: "north", parent_id: 3},
      %ChainChild{tenant_id: "south", parent_id: 4}
    ]

    {_, _, other_cache_key} =
      other_owners
      |> Ecto.assoc([:parent, :organization])
      |> Planner.plan(:all, Ecto.TestAdapter)

    assert cache_key == other_cache_key
  end

  test "excludes incomplete composite keys from a chained association" do
    query = Ecto.assoc(%ChainChild{tenant_id: "east"}, [:parent, :organization])
    {planned, _, _} = Planner.plan(query, :all, Ecto.TestAdapter)

    assert [%{expr: {:and, _, [false, _]}}] = planned.wheres
  end

  test "preloads a through association across a loaded composite belongs_to" do
    organization = %ChainOrganization{id: 7, active: true}

    parent = %ChainParent{
      id: 1,
      tenant_id: "east",
      organization_id: 7,
      organization: organization
    }

    child = %ChainChild{tenant_id: "east", parent_id: 1, parent: parent}

    assert %ChainChild{organization: ^organization} = TestRepo.preload(child, :organization)
  end

  test "uses one stable filter for a single composite owner" do
    first = Ecto.assoc(%Child{tenant_id: "east", parent_id: 1}, :parent)
    second = Ecto.assoc(%Child{tenant_id: "west", parent_id: 2}, :parent)

    {planned, params, cache_key} = Planner.plan(first, :all, Ecto.TestAdapter)
    {_, _, other_cache_key} = Planner.plan(second, :all, Ecto.TestAdapter)
    condition = planned.wheres |> hd() |> Map.fetch!(:expr) |> Macro.to_string()

    assert cache_key == other_cache_key
    assert Enum.map(params, &elem(&1, 0)) == ["east", 1]
    assert condition =~ "tenant_id"
    assert condition =~ "id"
    assert condition =~ "and"
    refute condition =~ "or"
  end

  test "preloads composite belongs_to with shared key components" do
    owners = [
      %Child{tenant_id: "east", parent_id: 1},
      %Child{tenant_id: "east", parent_id: 2},
      %Child{tenant_id: "west", parent_id: 1}
    ]

    Process.put(
      :test_repo_all_results,
      {3,
       [
         [1, "east", "east", 1],
         [2, "east", "east", 2],
         [1, "west", "west", 1]
       ]}
    )

    [c1, c2, c3] = TestRepo.preload(owners, :parent)

    assert %Parent{id: 1, tenant_id: "east"} = c1.parent
    assert %Parent{id: 2, tenant_id: "east"} = c2.parent
    assert %Parent{id: 1, tenant_id: "west"} = c3.parent
  end

  test "matches complete composite keys for multiple owners in Ecto.assoc" do
    owners = [
      %Child{tenant_id: "east", parent_id: 1},
      %Child{tenant_id: "west", parent_id: 2}
    ]

    {planned, params, cache_key} =
      owners
      |> Ecto.assoc(:parent)
      |> Planner.plan(:all, Ecto.TestAdapter)

    condition = planned.wheres |> hd() |> Map.fetch!(:expr) |> Macro.to_string()

    assert length(planned.wheres) == 1
    assert condition =~ " or "
    assert length(String.split(condition, " and ")) == 3
    assert Enum.map(params, &elem(&1, 0)) == ["east", 1, "west", 2]
    assert cache_key != :nocache

    other_owners = [
      %Child{tenant_id: "north", parent_id: 3},
      %Child{tenant_id: "south", parent_id: 4}
    ]

    {_, _, other_cache_key} =
      other_owners
      |> Ecto.assoc(:parent)
      |> Planner.plan(:all, Ecto.TestAdapter)

    assert cache_key == other_cache_key
  end

  test "applies association conditions to the entire composite owner filter" do
    assoc = Child.__schema__(:association, :parent)
    assoc = %{assoc | where: [tenant_id: "east"]}

    {planned, _, _} =
      assoc
      |> BelongsTo.assoc_query(nil, [{"east", 1}, {"west", 2}])
      |> Planner.plan(:all, Ecto.TestAdapter)

    assert {:and, _, [{:or, _, _}, _]} = hd(planned.wheres).expr
  end

  test "ignores incomplete composite keys among multiple owners in Ecto.assoc" do
    owners = [
      %Child{tenant_id: "east", parent_id: 1},
      %Child{tenant_id: "west", parent_id: nil}
    ]

    {planned, params, _} =
      owners
      |> Ecto.assoc(:parent)
      |> Planner.plan(:all, Ecto.TestAdapter)

    assert Enum.map(params, &elem(&1, 0)) == ["east", 1]
    refute Macro.to_string(hd(planned.wheres).expr) =~ " or "
  end

  test "skips owners with an incomplete composite key when preloading" do
    owners = [
      %Child{tenant_id: "east", parent_id: 1},
      %Child{tenant_id: "west", parent_id: nil}
    ]

    Process.put(:test_repo_all_results, {1, [[1, "east", "east", 1]]})
    on_exit(fn -> Process.delete(:test_repo_all_results) end)

    [east, west] = TestRepo.preload(owners, :parent)

    assert %Parent{id: 1, tenant_id: "east"} = east.parent
    assert west.parent == nil
  end

  test "ignores incomplete composite keys in Ecto.assoc" do
    query = Ecto.assoc(%Child{tenant_id: "east", parent_id: nil}, :parent)
    {planned, params, _} = Planner.plan(query, :all, Ecto.TestAdapter)

    assert params == []
    assert hd(planned.wheres).expr == false
  end
end
