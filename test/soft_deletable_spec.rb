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
end

class TestModel < ActiveRecord::Base
  extend SoftDeletable
  self.table_name = 'test_models'

  default_scope { where("#{table_name}.deleted <> ? OR #{table_name}.deleted is not ?", true, true) }
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
end
