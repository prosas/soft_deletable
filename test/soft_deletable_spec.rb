# frozen_string_literal: true

require 'minitest/autorun'
# require_relative 'test_helper'
require 'active_record'
require 'soft_deletable'
require 'byebug'

# Configuração do ActiveRecord para testes
ActiveRecord::Base.establish_connection(
  adapter: 'sqlite3',
  database: ':memory:'
)

# Criação da tabela temporária para testes
ActiveRecord::Schema.define do
  create_table :test_models, force: true do |t|
    t.boolean :deleted, default: false
    t.datetime :deleted_at
  end

  create_table :recover_parents, force: true do |t|
    t.boolean :deleted, default: false
  end

  create_table :recover_children, force: true do |t|
    t.integer :recover_parent_id
    t.boolean :deleted, default: false
  end

  create_table :recover_grandchildren, force: true do |t|
    t.integer :recover_child_id
    t.boolean :deleted, default: false
  end

  create_table :force_parents, force: true do |t|
    t.boolean :deleted, default: false
  end

  create_table :force_children, force: true do |t|
    t.integer :force_parent_id
    t.boolean :deleted, default: false
  end

  create_table :force_grandchildren, force: true do |t|
    t.integer :force_child_id
    t.boolean :deleted, default: false
  end

  create_table :force_independents, force: true do |t|
    t.integer :force_parent_id
    t.boolean :deleted, default: false
  end
end

class TestModel < ActiveRecord::Base
  extend SoftDeletable
  self.table_name = 'test_models'

  default_scope { where("#{table_name}.deleted <> ? OR #{table_name}.deleted is not ?", true, true) }
end

class RecoverParent < ActiveRecord::Base
  extend SoftDeletable
  has_many :recover_children, dependent: :destroy
  soft_destroy :deleted
end

class RecoverChild < ActiveRecord::Base
  extend SoftDeletable
  belongs_to :recover_parent
  has_many :recover_grandchildren, dependent: :destroy
  soft_destroy :deleted
end

class RecoverGrandchild < ActiveRecord::Base
  extend SoftDeletable
  belongs_to :recover_child
  soft_destroy :deleted
end

class ForceParent < ActiveRecord::Base
  extend SoftDeletable
  has_many :force_children, dependent: :destroy
  has_many :force_independents
  soft_destroy :deleted
end

class ForceChild < ActiveRecord::Base
  extend SoftDeletable
  belongs_to :force_parent
  has_many :force_grandchildren, dependent: :destroy
  soft_destroy :deleted, if: ->(_instance) { false }
end

class ForceGrandchild < ActiveRecord::Base
  extend SoftDeletable
  belongs_to :force_child
  soft_destroy :deleted, if: ->(_instance) { false }
end

class ForceIndependent < ActiveRecord::Base
  extend SoftDeletable
  belongs_to :force_parent
  soft_destroy :deleted
end

class SoftDeletableTest < Minitest::Test
  def setup
    @model = TestModel.create
  end

  def test_default_options
    TestModel.soft_destroy(:deleted)
    assert TestModel.where(deleted: false).exists?
  end

  def test_custom_options
    TestModel.soft_destroy(:deleted, default_scoped: false)
    refute TestModel.respond_to?(:default_scope)
  end

  def test_validation_before_destroy
    TestModel.soft_destroy(:deleted, if: ->(_instance) { false })
    @model.destroy
    assert @model.errors.any?
  end

  def test_custom_implementation_of_soft_delete
    TestModel.soft_destroy(:deleted) do |instance|
      instance.update_column(:deleted_at, Time.current)
    end
    @model.destroy
    assert @model.deleted_at.present?
  end

  def test_error_handling_when_attribute_is_updated
    TestModel.soft_destroy(:deleted)
    assert_raises(SoftDeletable::AttributeNotUpdate) do
      @model.deleted = true
    end
  end

  def test_error_handling_when_destroy_is_not_allowed
    TestModel.soft_destroy(:deleted, if: ->(_instance) { false })
    @model.destroy
    assert @model.errors.any?
  end

  def test_force_destroy_ignores_if_condition
    TestModel.soft_destroy(:deleted, if: ->(_instance) { false })
    @model.destroy(force_destroy: true)
    assert_equal true, @model.deleted
    assert @model.errors.empty?
  end

  def test_force_destroy_false_still_respects_if_condition
    TestModel.soft_destroy(:deleted, if: ->(_instance) { false })
    @model.destroy(force_destroy: false)
    refute_equal true, @model.deleted
    assert @model.errors.any?
  end

  def test_recover_reverts_default_destroy
    TestModel.soft_destroy(:deleted)
    @model.destroy
    assert_equal true, @model.deleted

    @model.recover
    assert_equal false, @model.deleted
  end

  def test_custom_recover_implementation
    TestModel.soft_destroy(:deleted, recover: ->(instance) { instance.update_column(:deleted_at, nil) }) do |instance|
      instance.update_column(:deleted_at, Time.current)
    end
    @model.destroy
    assert @model.deleted_at.present?

    @model.recover
    assert_nil @model.deleted_at
  end

  def test_all_deleted_returns_soft_deleted_records
    TestModel.soft_destroy(:deleted)
    kept = TestModel.create
    @model.destroy

    deleted_records = TestModel.all_deleted
    assert_includes deleted_records, @model
    refute_includes deleted_records, kept
  end

  def test_recover_restores_destroyed_associations_recursively
    parent = RecoverParent.create
    child = RecoverChild.create(recover_parent: parent)
    grandchild = RecoverGrandchild.create(recover_child: child)

    parent.destroy

    assert_includes RecoverParent.all_deleted, parent
    assert_includes RecoverChild.all_deleted, child
    assert_includes RecoverGrandchild.all_deleted, grandchild

    parent.recover

    refute_includes RecoverParent.all_deleted, parent
    refute_includes RecoverChild.all_deleted, child
    refute_includes RecoverGrandchild.all_deleted, grandchild
    assert_equal false, parent.reload.deleted
    assert_equal false, child.reload.deleted
    assert_equal false, grandchild.reload.deleted
  end

  def test_destroy_without_force_does_not_bypass_association_if
    parent = ForceParent.create
    child = ForceChild.create(force_parent: parent)
    grandchild = ForceGrandchild.create(force_child: child)

    parent.destroy

    assert_equal true, parent.reload.deleted
    refute_equal true, child.reload.deleted
    refute_equal true, grandchild.reload.deleted
  end

  def test_force_destroy_is_forwarded_to_dependent_associations
    parent = ForceParent.create
    child = ForceChild.create(force_parent: parent)
    grandchild = ForceGrandchild.create(force_child: child)

    parent.destroy(force_destroy: true)

    assert_equal true, parent.reload.deleted
    assert_equal true, child.reload.deleted
    assert_equal true, grandchild.reload.deleted
  end

  def test_force_destroy_does_not_destroy_associations_without_dependent
    parent = ForceParent.create
    independent = ForceIndependent.create(force_parent: parent)

    parent.destroy(force_destroy: true)

    assert_equal true, parent.reload.deleted
    refute_equal true, independent.reload.deleted
  end

  def test_force_destroy_does_not_leak_to_later_destroys
    parent = ForceParent.create
    ForceChild.create(force_parent: parent)
    parent.destroy(force_destroy: true)

    other_parent = ForceParent.create
    other_child = ForceChild.create(force_parent: other_parent)
    other_parent.destroy

    refute_equal true, other_child.reload.deleted
  end
end
