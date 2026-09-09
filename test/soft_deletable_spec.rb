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
    t.string :identify_destroy
  end

  create_table :recover_parents, force: true do |t|
    t.boolean :deleted, default: false
    t.datetime :deleted_at
    t.string :identify_destroy
  end

  create_table :recover_children, force: true do |t|
    t.integer :recover_parent_id
    t.boolean :deleted, default: false
    t.datetime :deleted_at
    t.string :identify_destroy
  end

  create_table :recover_grandchildren, force: true do |t|
    t.integer :recover_child_id
    t.boolean :deleted, default: false
    t.datetime :deleted_at
    t.string :identify_destroy
  end

  create_table :custom_column_models, force: true do |t|
    t.boolean :deleted, default: false
    t.datetime :removed_at
    t.string :removal_id
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

class CustomColumnModel < ActiveRecord::Base
  extend SoftDeletable
  self.table_name = 'custom_column_models'
  soft_destroy :deleted, deleted_at_column: :removed_at, indentify_destroy_column: :removal_id
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
    assert @model.deleted_at.present?
    assert @model.identify_destroy.present?

    @model.recover
    assert_equal false, @model.deleted
    assert_nil @model.deleted_at
    assert_nil @model.identify_destroy
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
    assert_nil parent.deleted_at
    assert_nil parent.identify_destroy
    assert_nil child.deleted_at
    assert_nil grandchild.deleted_at
  end

  def test_default_destroy_fills_deleted_at_and_identify_destroy
    TestModel.soft_destroy(:deleted)
    @model.destroy

    assert_equal true, @model.deleted
    assert @model.deleted_at.present?
    assert @model.identify_destroy.present?
  end

  def test_identify_destroy_is_unique_per_destroy
    TestModel.soft_destroy(:deleted)
    other = TestModel.create
    @model.destroy
    other.destroy

    refute_equal @model.identify_destroy, other.identify_destroy
  end

  def test_custom_deleted_at_and_indentify_destroy_columns
    model = CustomColumnModel.create
    model.destroy

    assert_equal true, model.deleted
    assert model.removed_at.present?
    assert model.removal_id.present?
  end

  def test_custom_destroy_raises_when_metadata_is_cleared
    TestModel.soft_destroy(:deleted) do |instance|
      instance.update_columns(deleted: true, deleted_at: nil, identify_destroy: nil)
    end

    error = assert_raises(SoftDeletable::MissingDestroyAttribute) do
      @model.destroy
    end
    assert_match(/deleted_at/, error.message)
    assert_match(/identify_destroy/, error.message)

    @model.reload
    refute_equal true, @model.deleted
    assert_nil @model.deleted_at
    assert_nil @model.identify_destroy
  end

  def test_custom_destroy_keeps_metadata_set_before_block
    TestModel.soft_destroy(:deleted) do |instance|
      instance.update_column(:deleted, true)
    end
    @model.destroy

    assert_equal true, @model.deleted
    assert @model.deleted_at.present?
    assert @model.identify_destroy.present?
  end
end
