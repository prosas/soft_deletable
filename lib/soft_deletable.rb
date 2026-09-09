# frozen_string_literal: true

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
# O mesmo valor é ecoado para as associações com dependent: :destroy (o Rails
# chama .destroy sem argumentos nos filhos; o flag segue via estado da thread).
#	 soft_destroy :excluido, if: ->(instance) { instance.can_remove? }
# >> registro.destroy
# >> registro.destroy(force_destroy: true)

module SoftDeletable
  extend ActiveSupport::Concern

  FORCE_DESTROY_THREAD_KEY = :soft_deletable_force_destroy

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

  # == Parameters:
  # @param [Symbol] coluna que marca como excluido o registro.
  # @param options [Hash] opções.
  #        default_scoped [Booleam]: para usar default_scoped ou não
  #        if [Proc]: recebe proc que roda validação antes do destroy
  #        force_destroy [Boolean]: se igual a true, ignora a condição `if` e força o destroy (ecoado para dependent: :destroy) (ecoado para dependent: :destroy)
  #        message [String]: Mensagem de erro caso não seja possível remover o objeto
  #        recover [Proc]: implementação do recover; por padrão é self.update_column(column, false)
  # @param block [Block] a implementação do soft delete, por padrão é self.update_column(column, true)
  #
  def soft_destroy(column, options = {}, &block)
    default_options = { default_scoped: true, if: ->(_instance) { true }, force_destroy: false, message: 'já foi deletado' }
    default_options.merge!(options)
    default_options[:recover] ||= ->(instance) { instance.update_column(column, false) }

    if ActiveRecord::VERSION::MAJOR <= 6
      default_scope { where("#{table_name}.#{column} is not ?", true) } if default_options[:default_scoped]
    elsif default_options[:default_scoped]
      default_scope { where("#{table_name}.#{column} <> ? OR #{table_name}.#{column} is not true", true) }
    end

    define_method("#{column}=") do |_value|
      raise(AttributeNotUpdate, AttributeNotUpdate.new(column).message)
    end

    define_method(:destroy) do |force_destroy: default_options[:force_destroy]|
      force_destroy = true if Thread.current[SoftDeletable::FORCE_DESTROY_THREAD_KEY] == true

      if force_destroy == true || default_options[:if].call(self)
        previous_force_destroy = Thread.current[SoftDeletable::FORCE_DESTROY_THREAD_KEY]
        Thread.current[SoftDeletable::FORCE_DESTROY_THREAD_KEY] = true if force_destroy == true

        begin
          run_callbacks(:destroy) do
            run_callbacks(:commit) do
              if block
                block.call(self)
              else
                update_column(column, true)
              end
            end
          end
        ensure
          Thread.current[SoftDeletable::FORCE_DESTROY_THREAD_KEY] = previous_force_destroy
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
