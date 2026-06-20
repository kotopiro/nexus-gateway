defmodule NexusGateway.PermissionsTest do
  use ExUnit.Case, async: true

  import Bitwise

  alias NexusGateway.Permissions

  describe "has?/2" do
    test "フラグが含まれていれば true" do
      set = Permissions.send_messages() ||| Permissions.view_channel()
      assert Permissions.has?(set, Permissions.send_messages())
    end

    test "フラグが含まれていなければ false" do
      set = Permissions.view_channel()
      refute Permissions.has?(set, Permissions.manage_roles())
    end

    test "administrator は他の全フラグを暗黙的に持つ" do
      set = Permissions.administrator()
      assert Permissions.has?(set, Permissions.manage_roles())
      assert Permissions.has?(set, Permissions.send_messages())
    end

    test "none() はどのフラグも持たない" do
      refute Permissions.has?(Permissions.none(), Permissions.view_channel())
    end

    test "all() は全フラグを持つ" do
      set = Permissions.all()
      assert Permissions.has?(set, Permissions.manage_roles())
      assert Permissions.has?(set, Permissions.connect_voice())
    end
  end

  describe "can_send_messages?/2 (Stub経由)" do
    test "DataSource.Stub は常に全権限を返すので true になる" do
      assert Permissions.can_send_messages?("user_x", "ch_x") == true
    end
  end

  describe "can_send_typing?/2 (Stub経由)" do
    test "DataSource.Stub は常に全権限を返すので true になる" do
      assert Permissions.can_send_typing?("user_x", "ch_x") == true
    end
  end
end
