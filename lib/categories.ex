defmodule Bonfire.Classify.Categories do

  alias Bonfire.Common.Utils
  import Bonfire.Common.Config, only: [repo: 0]
  import Utils, only: [maybe_get: 2, maybe_get: 3]

  alias Bonfire.Classify.Category
  alias Bonfire.Classify.Category.Queries

  alias Bonfire.Me.Characters

  @facet_name "Category"

  # queries

  def one(filters), do: repo().single(Queries.query(Category, filters))

  def get(id) do
    if Bonfire.Common.Utils.is_ulid?(id) do
      one([:default, id: id])
    else
      one([:default, username: id])
    end
  end

  def many(filters \\ []), do: {:ok, repo().many(Queries.query(Category, filters))}
  def list(), do: many([:default])


  ## mutations

  @doc """
  Create a brand-new category object, with info stored in profile and character mixins
  """
  def create(creator, attrs)

  def create(creator, %{category: %{} = cat_attrs} = params) do
    create(
      creator,
      params
      |> Map.merge(cat_attrs)
      |> Map.delete(:category)
    )
  end

  def create(creator, %{facet: facet} = params) when not is_nil(facet) do
    with attrs <- attrs_prepare(params) do
      attempt_create(creator, attrs)
    end
  end

  def create(creator, params) do
    create(creator, Map.put(params, :facet, @facet_name))
  end

  defp attempt_create(creator, attrs, attempt \\ 1) do
    #IO.inspect(attempt: attempt)
    #IO.inspect(creating_category: attrs)

    with {:ok, category} <- do_create(creator, attrs) do
      #IO.inspect(category: category)
      {:ok, category}

    else
      {:error, cs} ->
        if name_already_taken?(cs) and attempt < 10 do
          attempt_create(creator, do_put_generated_username(attrs, attrs.character.username<>"#{attempt+1}"), attempt+1)
        else
          {:error, cs}
        end
      e ->
        #IO.inspect(e: e)
        e
    end

  end

  defp do_create(creator, attrs) do
    repo().transact_with(fn ->

      # TODO: check that the category doesn't already exist (same name and parent)

      with {:ok, category} <- insert_category(creator, attrs),
           attrs <- attrs_mixins_with_id(attrs, category),
           {:ok, tag} <-
             Bonfire.Tag.Tags.make_tag(creator, category, attrs) do
          # # FIXME
          #  {:ok, profile} <- CommonsPub.Profiles.create(creator, attrs),
          #  {:ok, character} <-
          #    CommonsPub.Characters.create(creator, attrs) do
        category = %{category | tag: tag} #, character: character, profile: profile}

        # add to search index
        maybe_index(category)

        # post as an activity - FIXME
        # act_attrs = %{verb: "created", is_local: is_nil(maybe_get(category, :character) |> maybe_get(:peer_id))}
        # {:ok, activity} = Activities.create(creator, category, act_attrs)
        # repo().preload(category, :caretaker)
        # :ok = publish(creator, category.caretaker, category.character, activity)
        # :ok = ap_publish("create", category)

        {:ok, category}
      end
    end)
  end

  def maybe_create_hashtag(creator, "#" <> tag) do
    maybe_create_hashtag(creator, tag)
  end

  def maybe_create_hashtag(creator, tag) do
    create(
      creator,
      %{}
      |> Map.put(:name, tag)
      |> Map.put(:prefix, "#")
      |> Map.put(:facet, "Hashtag")
    )
  end

  defp attrs_prepare(attrs) do
    attrs
    |> Map.put(:profile, Map.merge(attrs, Map.get(attrs, :profile, %{})))
    |> Map.put(:character, Map.merge(attrs, Map.get(attrs, :character, %{})))
    |> attrs_with_parent_category()
    |> attrs_with_username()
  end

  def attrs_with_parent_category(%{parent_category: %{id: id} = parent_category} = attrs)
      when not is_nil(id) do
    put_attrs_with_parent_category(attrs, parent_category)
  end

  def attrs_with_parent_category(%{parent_category: id} = attrs)
      when is_binary(id) and id != "" do
    with {:ok, parent_category} <- get(id) do
      put_attrs_with_parent_category(attrs, parent_category)
    else
      _ ->
        put_attrs_with_parent_category(attrs, nil)
    end
  end

  def attrs_with_parent_category(%{parent_category_id: id} = attrs) when not is_nil(id) do
    attrs_with_parent_category(Map.put(attrs, :parent_category, id))
  end

  def attrs_with_parent_category(attrs) do
    put_attrs_with_parent_category(attrs, nil)
  end

  def put_attrs_with_parent_category(attrs, nil) do
    attrs
    |> Map.put(:parent_category, nil)
    |> Map.put(:parent_category_id, nil)
  end

  def put_attrs_with_parent_category(attrs, parent_category) do
    attrs
    |> Map.put(:parent_category, parent_category)
    |> Map.put(:parent_category_id, parent_category.id)
  end

  # todo: improve

  def attrs_with_username(
        %{character: %{username: preferred_username}} = attrs
      )
      when not is_nil(preferred_username) and preferred_username != "" do
    put_generated_username(attrs, preferred_username)
  end

  def attrs_with_username(%{profile: %{name: name}} = attrs) do
    put_generated_username(attrs, name)
  end

  def attrs_with_username(attrs) do
    attrs
  end

  def put_generated_username(
        %{parent_category: %{character: %{username: parent_name}}} = attrs,
        name
      )
      when not is_nil(name) and not is_nil(parent_name) do
    do_put_generated_username(attrs, name <> "-" <> parent_name)
  end

  def put_generated_username(
        %{parent_category: %{profile: %{name: parent_name}}} = attrs,
        name
      )
      when not is_nil(name) and not is_nil(parent_name) do
    do_put_generated_username(attrs, name <> "-" <> parent_name)
  end

  def put_generated_username(
        %{parent_category: %{name: parent_name}} = attrs,
        name
      )
      when not is_nil(name) and not is_nil(parent_name) do
    do_put_generated_username(attrs, name <> "-" <> parent_name)
  end

  def put_generated_username(attrs, name) do
    # <> "-" <> attrs.facet
    do_put_generated_username(attrs, name)
  end

  def do_put_generated_username(attrs, username) do
    attrs |> Map.put(:character, Map.merge(Map.get(attrs, :character, %{}), %{username: username}))
  end

  def name_already_taken?(%Ecto.Changeset{} = changeset) do
    #IO.inspect(changeset)
    cs = Map.get(changeset.changes, :character, changeset)
    case cs.errors[:username] do
      {"has already been taken", _} -> true
      _ -> false
    end
  end

  defp attrs_mixins_with_id(attrs, category) do
    Map.put(attrs, :id, category.id)
  end

  defp insert_category(user, attrs) do
    #IO.inspect(inserting_category: attrs)
    cs = Category.create_changeset(user, attrs)
    with {:ok, category} <- repo().insert(cs) do
      {:ok, category}
    end
  end

  def update(user, %Category{} = category, %{category: %{} = cat_attrs} = attrs) do
    update(
      user,
      category,
      attrs
      |> Map.merge(cat_attrs)
      |> Map.delete(:category)
    )
  end

  def update(user, %Category{} = category, attrs) do
    category = repo().preload(category, [:profile, :character])

    #IO.inspect(category)
    #IO.inspect(attrs)

    repo().transact_with(fn ->
      # :ok <- publish(category, :updated)
      with {:ok, category} <- repo().update(Category.update_changeset(category, attrs)) do
          #  {:ok, profile} <- CommonsPub.Profiles.update(user, category.profile, attrs),
          #  {:ok, character} <- Characters.update(user, category.character, attrs) do
        # {:ok, %{category | character: character, profile: profile}}
        {:ok, category}
      end
    end)
  end

  # Feeds

  # defp publish(%{outbox_id: creator_outbox}, %{outbox_id: caretaker_outbox}, category, activity) do
  #   feeds = [
  #     caretaker_outbox,
  #     creator_outbox,
  #     category.outbox_id,
  #     Feeds.instance_outbox_id()
  #   ]

  #   FeedActivities.publish(activity, feeds)
  # end

  # defp publish(%{outbox_id: creator_outbox}, _, category, activity) do
  #   feeds = [category.outbox_id, creator_outbox, Feeds.instance_outbox_id()]
  #   FeedActivities.publish(activity, feeds)
  # end

  # defp publish(_, _, category, activity) do
  #   feeds = [category.outbox_id, Feeds.instance_outbox_id()]
  #   FeedActivities.publish(activity, feeds)
  # end

  # defp ap_publish(verb, communities) when is_list(communities) do
  #   APPublishWorker.batch_enqueue(verb, communities)
  #   :ok
  # end

  # defp ap_publish(verb, %{character: %{peer_id: nil}} = category) do
  #   APPublishWorker.enqueue(verb, %{"context_id" => category.id})
  #   :ok
  # end

  # defp ap_publish(_, _), do: :ok

  def indexing_object_format(%{id: _} = obj) do

    obj = Bonfire.Repo.maybe_preload(obj, [:profile, :character])

    # # FIXME
    # follower_count =
    #   case CommonsPub.Follows.FollowerCounts.one(context: obj.id) do
    #     {:ok, struct} -> struct.count
    #     {:error, _} -> nil
    #   end

    # icon = CommonsPub.Uploads.remote_url_from_id(character.icon_id)
    # image = CommonsPub.Uploads.remote_url_from_id(character.image_id)

    canonical_url = Bonfire.Me.Characters.character_url(obj)

    %{
      "index_type" => "Category",
      "facet" => obj.facet,
      "id" => obj.id,
      "url" => canonical_url,
      # "followers" => %{
      #   "totalCount" => follower_count
      # },
      "context" => indexing_object_format(Map.get(obj, :parent_category)),
      # "icon" => icon,
      # "image" => image,
      "name" => maybe_get(obj, :name) || maybe_get(obj, :profile) |> maybe_get(:name),
      "username" => Bonfire.Me.Characters.display_username(obj),
      # "summary" => character.summary,
      "createdAt" => obj.published_at,
      # home instance of object
      "index_instance" => Bonfire.Search.Indexer.host(canonical_url)
    }
  end

  def indexing_object_format(_), do: nil

  defp maybe_index(obj) do
    object = indexing_object_format(obj)

    if Utils.module_enabled?(Bonfire.Search.Indexer) do
      Bonfire.Search.Indexer.maybe_index_object(object)
    else
      :ok
    end
  end


  def soft_delete(%Category{} = c) do
    repo().transact_with(fn ->
      with {:ok, c} <- Bonfire.Repo.Delete.soft_delete(c) do
        {:ok, c}
      else
        e ->
          {:error, e}
      end
    end)
  end

  def soft_delete(id) when is_binary(id) do
    with {:ok, c} <- get(id) do
      soft_delete(c)
    end
  end

end
