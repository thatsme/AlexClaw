defmodule AlexClaw.Database.RestoreTest do
  @moduledoc """
  Staging and discarding an uploaded dump.

  `run/1` itself shells out to psql against the live database, so the tests
  here cover everything around it: that a file is staged out of the upload's
  temporary directory, that it is discarded on refusal, and that a restore
  asked to run against a file that is gone says so rather than proceeding.
  """
  use ExUnit.Case, async: true

  alias AlexClaw.Database.Restore

  defp uploaded(contents) do
    path = Path.join(System.tmp_dir!(), "upload-#{System.unique_integer([:positive])}.sql")
    File.write!(path, contents)
    on_exit(fn -> File.rm(path) end)
    path
  end

  describe "stage/1" do
    test "copies the upload somewhere it will outlive the request" do
      source = uploaded("SELECT 1;")

      {:ok, staged} = Restore.stage(source)

      assert File.read!(staged) == "SELECT 1;"
      refute staged == source
      Restore.discard(staged)
    end

    test "leaves the original alone" do
      source = uploaded("SELECT 1;")

      {:ok, staged} = Restore.stage(source)

      assert File.exists?(source)
      Restore.discard(staged)
    end

    test "gives each upload its own path" do
      source = uploaded("SELECT 1;")

      {:ok, first} = Restore.stage(source)
      {:ok, second} = Restore.stage(source)

      refute first == second
      Restore.discard(first)
      Restore.discard(second)
    end

    test "reports a source that is not there" do
      assert {:error, :enoent} = Restore.stage("/nonexistent/upload.sql")
    end

    test "stages an empty file rather than deciding it is not worth staging" do
      {:ok, staged} = Restore.stage(uploaded(""))

      assert File.read!(staged) == ""
      Restore.discard(staged)
    end
  end

  describe "discard/1" do
    test "removes a staged file" do
      {:ok, staged} = Restore.stage(uploaded("SELECT 1;"))

      assert :ok = Restore.discard(staged)
      refute File.exists?(staged)
    end

    # Discarding runs on the refusal path and after a restore, so it has to
    # tolerate a file that is already gone.
    test "is a no-op for a file that is already gone" do
      assert :ok = Restore.discard("/nonexistent/staged.sql")
    end
  end

  describe "run/1" do
    # The challenge can be answered minutes later, by which time a tmp cleaner
    # may have taken the file. Shelling out to psql with a missing -f argument
    # would be a worse way to find out.
    test "refuses a staged file that has disappeared" do
      assert {:error, message} = Restore.run("/nonexistent/staged.sql")
      assert message =~ "no longer available"
    end
  end
end
