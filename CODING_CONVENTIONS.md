# Elixir Coding Conventions

This document defines idiomatic Elixir patterns for any project running on the BEAM. These are not style preferences — they reflect how the runtime actually works. Writing Elixir that looks like Python or Ruby is not acceptable, even if it compiles and runs.

---

## The BEAM Philosophy

The BEAM is not a faster Python runtime. It is a fault-tolerant, concurrent, distributed virtual machine designed for systems that must run forever. Every pattern in this document exists because it maps to how the BEAM works:

- **Processes are cheap** — spawn them, let them crash, restart them
- **Immutability is enforced** — data does not change, it is transformed
- **Pattern matching is the primary dispatch mechanism** — not if/else chains
- **Supervision is built into the runtime** — use it, do not work around it
- **"Let it crash"** is a design principle, not laziness

If you are uncomfortable with any of these, read [Programming Elixir](https://pragprog.com/titles/elixir16/programming-elixir-1-6/) before contributing.

---

## Formatting

Run `mix format` before every commit. No exceptions. CI enforces this.

A `.formatter.exs` is in the repository root. Do not modify it without discussion.

---

## Pattern Matching

Pattern matching is the primary tool for control flow, destructuring, and dispatch. Use it everywhere.

### Match in function heads, not in the body

```elixir
# Wrong
def process(result) do
  if elem(result, 0) == :ok do
    value = elem(result, 1)
    do_something(value)
  end
end

# Right
def process({:ok, value}), do: do_something(value)
def process({:error, reason}), do: handle_error(reason)
```

### Match in receive and case, not with conditionals

```elixir
# Wrong
def handle_message(msg) do
  if msg[:type] == "ping" do
    :pong
  else
    :unknown
  end
end

# Right
def handle_message(%{"type" => "ping"}), do: :pong
def handle_message(_msg), do: :unknown
```

### Use guards for type and value constraints

```elixir
def divide(a, b) when is_number(a) and is_number(b) and b != 0 do
  {:ok, a / b}
end
def divide(_, 0), do: {:error, :division_by_zero}
def divide(_, _), do: {:error, :invalid_arguments}
```

---

## Error Handling

### Return tagged tuples — never raise for expected failures

```elixir
# Wrong — raises for expected conditions
def find_user!(id) do
  Repo.get!(User, id)
end

# Right — returns a tagged tuple
def find_user(id) do
  case Repo.get(User, id) do
    nil -> {:error, :not_found}
    user -> {:ok, user}
  end
end
```

### Use `with` for multi-step operations

```elixir
# Wrong — nested case pyramid
case authenticate(token) do
  {:ok, user} ->
    case authorize(user, :write) do
      :ok ->
        case save(data) do
          {:ok, record} -> {:ok, record}
          {:error, reason} -> {:error, reason}
        end
      {:error, reason} -> {:error, reason}
    end
  {:error, reason} -> {:error, reason}
end

# Right
with {:ok, user} <- authenticate(token),
     :ok <- authorize(user, :write),
     {:ok, record} <- save(data) do
  {:ok, record}
end
```

### Use `Repo.get` not `Repo.get!` + rescue

```elixir
# Wrong — try/rescue for flow control is Python thinking
try do
  record = Repo.get!(Model, id)
  {:ok, record}
rescue
  Ecto.NoResultsError -> {:error, :not_found}
end

# Right
case Repo.get(Model, id) do
  nil -> {:error, :not_found}
  record -> {:ok, record}
end
```

### Use `Integer.parse` not `String.to_integer` + rescue

```elixir
# Wrong
try do
  {:ok, String.to_integer(value)}
rescue
  ArgumentError -> {:error, :invalid}
end

# Right
case Integer.parse(value) do
  {n, ""} -> {:ok, n}
  _ -> {:error, :invalid}
end
```

### Never swallow errors silently

```elixir
# Wrong — hides bugs completely
try do
  do_something()
rescue
  _ -> nil
end

# Acceptable — at minimum log what happened
try do
  do_something()
rescue
  e ->
    Logger.warning("do_something failed: #{Exception.message(e)}", error: e)
    {:error, :unexpected}
end

# Best — let it crash, let the supervisor restart
do_something()
```

Silent `rescue _` makes the system appear healthy when it is not. Supervisors exist to handle crashes. Use them.

### `!` functions are for programmer errors only

Bang functions (`get!`, `fetch!`, `parse!`) raise on failure. Use them only when failure means the program itself is wrong — misconfigured, missing required data at boot time. Never use them for expected runtime failures like "user not found" or "invalid input."

---

## Atoms

### Never create atoms from runtime strings

Atoms are never garbage collected. Each unique atom created from a runtime string is a permanent memory allocation.

```elixir
# Wrong — memory leak, will eventually crash the VM
key = String.to_atom("provider_#{id}")
key = :"#{module_name}_handler"

# Right — use tuples as keys
key = {:provider, id}
key = {module_name, :handler}
```

The only acceptable use of `String.to_atom/1` is with a compile-time known, bounded set of values. If the value comes from user input, a database, or any external source, use a tuple or string key instead.

`String.to_existing_atom/1` is safer but still requires the atom to have been created at compile time.

---

## Pipes

### Only pipe when there is an actual transformation chain

```elixir
# Wrong — single-value pipe adds noise
result = value |> transform()

# Right
result = transform(value)
```

### Keep pipe chains readable — one transformation per line

```elixir
# Wrong — unreadable wall of pipes
result = input |> String.trim() |> String.downcase() |> String.replace(" ", "_") |> String.slice(0, 50)

# Right
result =
  input
  |> String.trim()
  |> String.downcase()
  |> String.replace(" ", "_")
  |> String.slice(0, 50)
```

---

## Control Flow

### Prefer `unless` over `if not` for single-branch negation

```elixir
# Wrong
if not valid?(x), do: handle_invalid(x)

# Right
unless valid?(x), do: handle_invalid(x)
```

### Never use `unless...else`

Double negation is hard to reason about. `unless` with an `else` branch is explicitly discouraged by the Elixir style guide.

```elixir
# Wrong
unless disabled? do
  :active
else
  :inactive
end

# Right
if disabled? do
  :inactive
else
  :active
end
```

### Remove identity case expressions

```elixir
# Wrong — noise
result = case value do
  x -> x
end

# Right
result = value
```

### Avoid deeply nested conditionals — flatten with `with` or function heads

```elixir
# Wrong
def handle(params) do
  if Map.has_key?(params, :user_id) do
    if Map.has_key?(params, :action) do
      if params.action in [:read, :write] do
        execute(params)
      else
        {:error, :invalid_action}
      end
    else
      {:error, :missing_action}
    end
  else
    {:error, :missing_user_id}
  end
end

# Right
def handle(%{user_id: _, action: action} = params) when action in [:read, :write] do
  execute(params)
end
def handle(%{user_id: _, action: _}), do: {:error, :invalid_action}
def handle(%{action: _}), do: {:error, :missing_user_id}
def handle(_), do: {:error, :missing_action}
```

---

## Lists and Enumerables

### Never append with `++` in loops

`list ++ [item]` copies the entire list on every iteration. This is O(n²).

```elixir
# Wrong — O(n²)
Enum.reduce(items, [], fn item, acc ->
  acc ++ [transform(item)]
end)

# Right — prepend O(1), reverse once O(n)
items
|> Enum.reduce([], fn item, acc -> [transform(item) | acc] end)
|> Enum.reverse()

# Better — just use Enum.map
Enum.map(items, &transform/1)
```

### Prefer `Enum` over manual recursion for collection operations

```elixir
# Wrong — manual recursion for a standard operation
defp sum([]), do: 0
defp sum([h | t]), do: h + sum(t)

# Right
Enum.sum(items)
```

### Use `Stream` for lazy evaluation of large collections

```elixir
# Wrong — loads everything into memory
File.read!("large_file.log")
|> String.split("\n")
|> Enum.filter(&String.contains?(&1, "ERROR"))
|> Enum.take(100)

# Right — lazy, processes line by line
File.stream!("large_file.log")
|> Stream.filter(&String.contains?(&1, "ERROR"))
|> Enum.take(100)
```

---

## Strings

### Use string interpolation, not concatenation

```elixir
# Wrong
"Hello " <> name <> ", you are " <> Integer.to_string(age) <> " years old."

# Right
"Hello #{name}, you are #{age} years old."
```

### Use sigils for complex strings and patterns

```elixir
# Regex
pattern = ~r/^\d{4}-\d{2}-\d{2}$/

# Multiline strings
query = """
SELECT *
FROM users
WHERE active = true
"""

# String lists
roles = ~w(admin editor viewer)
```

---

## Structs and Maps

### Use structs for domain entities, maps for ad-hoc data

```elixir
# Wrong — map for a domain entity with known fields
user = %{name: "Alex", email: "alex@example.com", role: :admin}

# Right — struct enforces the shape
defmodule User do
  defstruct [:name, :email, :role]
end
user = %User{name: "Alex", email: "alex@example.com", role: :admin}
```

### Use `@enforce_keys` for required fields

Fields that must always be present should be enforced at compile time, not validated at runtime.

```elixir
# Wrong — missing required fields only fail at runtime, maybe
defmodule Connection do
  defstruct [:host, :port, timeout: 5_000]
end

# Right — missing :host or :port raises at compile time
defmodule Connection do
  @enforce_keys [:host, :port]
  defstruct [:host, :port, timeout: 5_000]
end
```

### Always match on the struct type when pattern matching structs

```elixir
# Wrong — matches any map with a name key
def greet(%{name: name}), do: "Hello #{name}"

# Right — only matches User structs
def greet(%User{name: name}), do: "Hello #{name}"
```

### Use `Map.get/3` with a default, not `Map.get/2` + nil check

```elixir
# Wrong
timeout = Map.get(config, :timeout)
timeout = if timeout == nil, do: 5000, else: timeout

# Right
timeout = Map.get(config, :timeout, 5000)
```

---

## OTP and Processes

### Always use Task.Supervisor for fire-and-forget tasks

```elixir
# Wrong — crash is invisible, no restart, no monitoring
Task.start(fn -> do_background_work() end)

# Right — crash is reported, supervised
Task.Supervisor.start_child(MyApp.TaskSupervisor, fn -> do_background_work() end)
```

Add the supervisor to your application tree:

```elixir
# application.ex
children = [
  {Task.Supervisor, name: MyApp.TaskSupervisor},
  # ...
]
```

### Use `handle_continue/2` for post-init work — never `send(self(), :init)`

```elixir
# Wrong — works, but sends a message through the mailbox unnecessarily;
# another message could arrive and be processed before :do_init
def init(args) do
  send(self(), :do_init)
  {:ok, initial_state(args)}
end

def handle_info(:do_init, state) do
  {:noreply, do_heavy_init(state)}
end

# Right — handle_continue runs before any other message is processed
def init(args) do
  {:ok, initial_state(args), {:continue, :init}}
end

def handle_continue(:init, state) do
  {:noreply, do_heavy_init(state)}
end
```

### Do not call GenServer functions from within the same GenServer

This causes a deadlock. Extract the logic into a private function and call it directly.

```elixir
# Wrong — deadlock
def handle_call(:do_thing, _from, state) do
  result = GenServer.call(__MODULE__, :helper)
  {:reply, result, state}
end

# Right
def handle_call(:do_thing, _from, state) do
  result = compute_helper(state)
  {:reply, result, state}
end

defp compute_helper(state), do: ...
```

### Keep GenServer state minimal and callbacks thin

```elixir
# Wrong — business logic buried in callback
def handle_call({:process, data}, _from, state) do
  result =
    data
    |> validate()
    |> enrich()
    |> persist()
    |> notify()
  {:reply, result, %{state | last_processed: DateTime.utc_now()}}
end

# Right — callback delegates to pure functions
def handle_call({:process, data}, _from, state) do
  result = process(data)
  {:reply, result, update_state(state)}
end

defp process(data) do
  data
  |> validate()
  |> enrich()
  |> persist()
  |> notify()
end

defp update_state(state), do: %{state | last_processed: DateTime.utc_now()}
```

### Use `GenServer.call` for synchronous operations, `GenServer.cast` for fire-and-forget

```elixir
# Synchronous — caller waits for result
GenServer.call(pid, {:get, key})

# Asynchronous — caller does not wait
GenServer.cast(pid, {:update, key, value})
```

### Do not store large data in GenServer state

GenServer state lives in the process heap. Large binaries, growing lists, or cached datasets should live in ETS, a database, or a dedicated cache process.

### Use `Process.send_after` for recurring work, not `receive` loops

```elixir
# In GenServer init
def init(state) do
  schedule_tick()
  {:ok, state}
end

def handle_info(:tick, state) do
  do_periodic_work()
  schedule_tick()
  {:noreply, state}
end

defp schedule_tick do
  Process.send_after(self(), :tick, :timer.seconds(30))
end
```

### Never use the process dictionary for application state

`Process.put/2` and `Process.get/2` are global mutable state scoped to a process. They are
invisible to callers, invisible to supervisors, and make code untestable. The only acceptable
uses are Logger metadata and library internals.

```elixir
# Wrong — hidden state, impossible to test or inspect
Process.put(:current_user, user)
user = Process.get(:current_user)

# Right — pass state explicitly
def handle_request(conn, user) do
  do_work(conn, user)
end
```

### Supervision strategies

| Strategy | Use when |
|---|---|
| `:one_for_one` | Children are independent — default choice |
| `:one_for_all` | Children are interdependent — restart all on any failure |
| `:rest_for_one` | Children have ordered dependencies — restart failed + all started after it |

---

## Module Design

### `alias`, `use`, `import` — pick the right tool

```elixir
# alias — resolves a module name locally, no code is imported
alias MyApp.Accounts.User
# Now %User{} works instead of %MyApp.Accounts.User{}

# import — brings functions into scope; avoid unless the benefit is clear
import Ecto.Query, only: [from: 2, where: 3]

# use — injects code via __using__/1 macro, significant side effect
# Only use when a behaviour or macro injection is explicitly required
use GenServer
use Phoenix.LiveView
```

Prefer `alias` over `import`. Use `use` only when the library requires it (GenServer, LiveView,
Ecto.Schema, etc.). Never `use` a module just to avoid typing the full name.

### One module, one responsibility

A module that does too many things should be split. Signs a module needs splitting:

- More than ~300 lines
- Functions that could be grouped into clearly distinct namespaces
- Mix of pure business logic and side effects (DB, HTTP, IO)

### Use context modules (Phoenix pattern) for domain boundaries

```
MyApp.Accounts         # User, Session, Token operations
MyApp.Accounts.User    # Schema only
MyApp.Content          # Post, Comment, Tag operations
MyApp.Content.Post     # Schema only
```

Context modules are the public API. Schemas are private data structures.

### Extract shared helpers into dedicated modules

```elixir
# Wrong — same utility function copy-pasted across 5 modules
defp blank?(nil), do: true
defp blank?(""), do: true
defp blank?(_), do: false

# Right — one module, used everywhere
defmodule MyApp.Utils do
  def blank?(nil), do: true
  def blank?(""), do: true
  def blank?(_), do: false
end
```

### Keep `defp` functions close to the `def` that calls them

Callers before helpers. Public functions at the top of the module.

---

## Typespecs and Documentation

### Every public function gets `@spec`

```elixir
@spec find_user(integer()) :: {:ok, User.t()} | {:error, :not_found}
def find_user(id) do
```

### Every module gets `@moduledoc`

```elixir
defmodule MyApp.Accounts do
  @moduledoc """
  Manages user accounts, sessions, and authentication.
  """
```

### Use `@doc false` for intentionally undocumented public functions

If a function must be public (e.g., for use in tests or callbacks) but should not appear in documentation:

```elixir
@doc false
def __callback__, do: :ok
```

### Consistent timestamp types

Choose one timestamp type and use it across all schemas. `:utc_datetime` is recommended. Do not mix `:naive_datetime` and `:utc_datetime`.

---

## Ecto

### Use changesets for all data mutations

Never write directly to the database without a changeset. Changesets provide validation, type casting, and an audit trail.

```elixir
# Wrong
Repo.insert!(%User{name: name, email: email})

# Right
%User{}
|> User.changeset(%{name: name, email: email})
|> Repo.insert()
```

### Use `Ecto.Multi` for multi-step database operations

`Repo.transaction/1` with `with` works for simple cases. `Ecto.Multi` is the right tool when
you have multiple named steps, need to inspect which step failed, or want composable transaction
building.

```elixir
# Acceptable for simple two-step cases
Repo.transaction(fn ->
  with {:ok, user} <- create_user(params),
       {:ok, _log} <- create_audit_log(user) do
    user
  else
    {:error, reason} -> Repo.rollback(reason)
  end
end)

# Right for complex multi-step operations — named steps, clear failure attribution
Ecto.Multi.new()
|> Ecto.Multi.insert(:user, User.changeset(%User{}, params))
|> Ecto.Multi.insert(:profile, fn %{user: user} ->
  Profile.changeset(%Profile{}, %{user_id: user.id})
end)
|> Ecto.Multi.run(:notify, fn _repo, %{user: user} ->
  Notifications.send_welcome(user)
end)
|> Repo.transaction()
|> case do
  {:ok, %{user: user}} -> {:ok, user}
  {:error, :user, changeset, _} -> {:error, changeset}
  {:error, :notify, reason, _} -> {:error, reason}
end
```

### Never trigger N+1 queries — preload associations explicitly

```elixir
# Wrong — each access hits the database inside the loop
orders = Repo.all(Order)
Enum.each(orders, fn order -> IO.inspect(order.items) end)

# Right — single query with preload
orders = Repo.all(Order) |> Repo.preload(:items)
Enum.each(orders, fn order -> IO.inspect(order.items) end)
```

If you access an association that has not been preloaded, Ecto raises `Ecto.Association.NotLoaded`.
Never rescue that — fix the preload.

### Use `from` queries instead of raw SQL for standard operations

```elixir
# Acceptable for simple queries
Repo.get(User, id)
Repo.all(User)

# Right for complex queries
from(u in User,
  where: u.active == true and u.role == ^role,
  order_by: [desc: u.inserted_at],
  limit: ^limit
)
|> Repo.all()
```

---

## Security

### Never create atoms from user input

(See Atoms section above — this is also a security issue, not just a memory issue.)

### Always use `Plug.Crypto.secure_compare` for token/signature comparison

```elixir
# Wrong — timing attack vulnerability
signature == computed_signature

# Right — constant-time comparison
Plug.Crypto.secure_compare(signature, computed_signature)
```

### Never interpolate user input into HTML without escaping

```elixir
# Wrong — XSS vulnerability
html = "<p>Hello #{user_input}</p>"

# Right — in Phoenix templates, assign to a variable and let HEEx escape it
# In controllers, use Phoenix.HTML.html_escape/1
safe_input = Phoenix.HTML.html_escape(user_input)
```

### No hardcoded secrets, salts, or keys

```elixir
# Wrong
signing_salt: "my_app_salt"
secret_key: "hardcoded_secret"

# Right
signing_salt: Application.fetch_env!(:my_app, :signing_salt)
secret_key: System.fetch_env!("SECRET_KEY")
```

---

## Testing

### Test behaviour, not implementation

```elixir
# Wrong — tests internal function
test "parse_response transforms the map correctly" do
  assert MyModule.parse_response(%{...}) == %{...}
end

# Right — tests public contract
test "fetch_user returns {:ok, user} when user exists" do
  user = insert(:user)
  assert {:ok, ^user} = Accounts.fetch_user(user.id)
end
```

### Default to `async: true`

Tests should run concurrently unless they touch shared mutable state: database without the Ecto
sandbox, named processes, ETS tables, or global config.

```elixir
# Default for unit tests and context tests using the Ecto sandbox
use MyApp.DataCase, async: true

# Only false when sharing state that cannot be isolated
use MyApp.DataCase, async: false
```

### Use ExUnit tags to organize test suites

```elixir
@tag :integration
test "creates a record in the database" do

@tag :unit
test "validates email format" do
```

Run subsets with `mix test --only unit` or `mix test --exclude integration`.

### Use ExMachina (or equivalent) for test data — never raw structs

```elixir
# Wrong — brittle, couples tests to schema details
user = %User{id: 1, name: "Test", email: "test@test.com", role: :admin, ...}

# Right — factory handles defaults, tests specify only what matters
user = insert(:user, role: :admin)
```

### Test the error paths, not just the happy path

Every function that returns `{:error, reason}` should have at least one test that exercises that path.

---

## What This Is Not

This document covers Elixir/OTP code. It does not define conventions for:

- Python code — follow PEP 8
- JavaScript/TypeScript — follow the project's ESLint config
- SQL — use Ecto query syntax where possible; raw SQL in separate files with comments
- Shell scripts — follow Google Shell Style Guide

---

## Resources

- [Elixir Style Guide](https://github.com/christopheradams/elixir_style_guide)
- [Credo](https://github.com/rrrene/credo) — static analysis for Elixir style
- [Dialyxir](https://github.com/jeremyjh/dialyxir) — typespec verification
- [Programming Elixir](https://pragprog.com/titles/elixir16/programming-elixir-1-6/) — Dave Thomas
- [Designing Elixir Systems with OTP](https://pragprog.com/titles/jgotp/designing-elixir-systems-with-otp/) — James Edward Gray II
