# frozen_string_literal: true

require 'securerandom'
require 'active_support/current_attributes'

# Sobreescreve o método destroy padrão do ActiveRecord e implementa um soft delete
## Como usar
# Extenda o module SoftDeletable no model e chame o método soft_destroy passando como parâmetro
# a coluna que marca como excluido o registro.
# ```
# class Model
#	 soft_destroy :excluido
#	 ...
# end
# ```
# Agora posso chamar o método destroy
# >> registro = Model.first
# >> registro.destroy
# Para reverter, chame recover. O recover restaura a instância e, em seguida,
# percorre recursivamente as associações destruídas (has_many/has_one)
# chamando recover em cada uma.
# >> registro.recover
# Com implementação customizada via Proc, injete o recover pelas options:
#	 soft_destroy :excluido, recover: ->(instance) { instance.update_column(:excluido_em, nil) } do |instance|
#	   instance.update_column(:excluido_em, Time.current)
#	 end
# all_deleted retorna todos os registros deletados, usando unscoped para ignorar
# o default_scope (column false) e filtrar os marcados como excluídos.
# >> Model.all_deleted
# Para personalizar, sobreescreva o método original no model:
#	 def self.all_deleted
#	   unscoped.where.not(excluido_em: nil)
#	 end
# force_destroy: quando igual a true, ignora a condição `if` das options e executa
# o destroy mesmo assim. Qualquer outro valor continua respeitando o `if`.
#	 soft_destroy :excluido, if: ->(instance) { instance.can_remove? }
# >> registro.destroy
# >> registro.destroy(force_destroy: true)
# deleted_at_column: coluna datetime preenchida com o momento da exclusão (padrão :deleted_at).
# indentify_destroy_column: coluna preenchida com um identificador único da exclusão
# (padrão :identify_destroy).
# Na implementação customizada, a gem preenche essas colunas antes do bloco e,
# depois, exige que continuem preenchidas. Tudo roda em uma transaction.
# Se destroyed_by_association estiver presente, o filho reutiliza o
# indentify_destroy_column do pai, lido de SoftDeletable::Current pela chave
# id_nome_da_classe (ex: "123_RecoverParent").

module SoftDeletable
  extend ActiveSupport::Concern

  class Current < ActiveSupport::CurrentAttributes
    attribute :identify_destroys

    def self.id_nome_da_classe(id, nome_da_classe)
      "#{id}_#{nome_da_classe}"
    end

    def self.identify_destroy_hash
      identify_destroys || {}
    end

    def self.store_identify_destroy(record, value)
      key = id_nome_da_classe(record.id, record.class.base_class.name)
      self.identify_destroys = identify_destroy_hash.merge(key => value)
    end

    def self.fetch_identify_destroy(id, nome_da_classe)
      identify_destroy_hash[id_nome_da_classe(id, nome_da_classe)]
    end

    def self.identify_destroy_from_association(record)
      reflection = record.destroyed_by_association
      return unless reflection

      parent_id = record[reflection.foreign_key]
      return if parent_id.blank?

      fetch_identify_destroy(parent_id, reflection.active_record.base_class.name)
    end
  end

  class AttributeNotUpdate < StandardError
    attr_accessor :column

    def initialize(column)
      @column = column
      super
    end

    def message
      "Attribute #{@column} can`t be update"
    end
  end

  class MissingDestroyAttribute < StandardError
    attr_accessor :columns

    def initialize(columns)
      @columns = Array(columns)
      super("Attribute #{@columns.join(', ')} must remain present after destroy")
    end
  end

  # == Parameters:
  # @param [Symbol] coluna que marca como excluido o registro.
  # @param options [Hash] opções.
  #        default_scoped [Booleam]: para usar default_scoped ou não
  #        if [Proc]: recebe proc que roda validação antes do destroy
  #        force_destroy [Boolean]: se igual a true, ignora a condição `if` e força o destroy
  #        message [String]: Mensagem de erro caso não seja possível remover o objeto
  #        recover [Proc]: implementação do recover; por padrão é self.update_column(column, false)
  #        deleted_at_column [Symbol]: coluna datetime do momento da exclusão (padrão :deleted_at)
  #        indentify_destroy_column [Symbol]: coluna do identificador único da exclusão (padrão :identify_destroy)
  # @param block [Block] a implementação do soft delete, por padrão é self.update_column(column, true)
  #
  def soft_destroy(column, options = {}, &block)
    default_options = {
      default_scoped: true,
      if: ->(_instance) { true },
      force_destroy: false,
      message: 'já foi deletado',
      deleted_at_column: :deleted_at,
      indentify_destroy_column: :identify_destroy
    }
    default_options.merge!(options)
    deleted_at_column = default_options[:deleted_at_column]
    indentify_destroy_column = default_options[:indentify_destroy_column]
    default_options[:recover] ||= lambda { |instance|
      instance.update_columns(
        column => false,
        deleted_at_column => nil,
        indentify_destroy_column => nil
      )
    }

    if ActiveRecord::VERSION::MAJOR <= 6
      default_scope { where("#{table_name}.#{column} is not ?", true) } if default_options[:default_scoped]
    elsif default_options[:default_scoped]
      default_scope { where("#{table_name}.#{column} <> ? OR #{table_name}.#{column} is not true", true) }
    end

    define_method("#{column}=") do |_value|
      raise(AttributeNotUpdate, AttributeNotUpdate.new(column).message)
    end

    define_method(:destroy) do |force_destroy: default_options[:force_destroy]|
      if force_destroy == true || default_options[:if].call(self)
        identify_destroy_value = if destroyed_by_association
          SoftDeletable::Current.identify_destroy_from_association(self) || SecureRandom.uuid
        else
          SecureRandom.uuid
        end
        SoftDeletable::Current.store_identify_destroy(self, identify_destroy_value)

        transaction do
          run_callbacks(:destroy) do
            run_callbacks(:commit) do
              update_columns(
                deleted_at_column => Time.current,
                indentify_destroy_column => identify_destroy_value
              )

              if block
                block.call(self)
                reload
                missing = []
                missing << deleted_at_column if self[deleted_at_column].blank?
                missing << indentify_destroy_column if self[indentify_destroy_column].blank?
                raise MissingDestroyAttribute.new(missing) if missing.any?
              else
                update_column(column, true)
              end
            end
          end
        end
      else
        errors.add(column, default_options[:message])
        false
      end
    end

    define_method(:recover) do |visited = {}|
      key = [self.class.base_class.name, id]
      return if visited[key]

      visited[key] = true
      default_options[:recover].call(self)

      destroyed_associations.each do |record|
        record.recover(visited) if record.respond_to?(:recover)
      end
    end

    define_method(:destroyed_associations) do
      associations = self.class.reflect_on_all_associations(:has_many) +
                     self.class.reflect_on_all_associations(:has_one)

      associations.each_with_object([]) do |reflection, records|
        next if reflection.options[:through]
        next if reflection.polymorphic?

        klass = reflection.klass
        next unless klass.respond_to?(:all_deleted)

        scope = klass.all_deleted.where(reflection.foreign_key => id)
        scope = scope.where(reflection.type => self.class.base_class.name) if reflection.type
        records.concat(scope.to_a)
      rescue NameError
        next
      end
    end

    define_singleton_method(:all_deleted) do
      unscoped.where(column => true)
    end
  end
end
