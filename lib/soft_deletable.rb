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

module SoftDeletable
  extend ActiveSupport::Concern

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
  #        message [String]: Mensagem de erro caso não seja possível remover o objeto
  # @param block [Block] a implementação do soft delete, por padrão é self.update_column(column, true)
  #
  def soft_destroy(column, options = {}, &block)
    default_options = { default_scoped: true, if: ->(_instance) { true }, message: 'já foi deletado' }
    default_options.merge!(options)

    if ActiveRecord::VERSION::MAJOR <= 6
      default_scope { where("#{table_name}.#{column} is not ?", true) } if default_options[:default_scoped]
    elsif default_options[:default_scoped]
      default_scope { where("#{table_name}.#{column} <> ? OR #{table_name}.#{column} is not ? true", true) }
    end

    define_method("#{column}=") do |_value|
      raise(AttributeNotUpdate, AttributeNotUpdate.new(column).message)
    end

    define_method(:destroy) do
      if default_options[:if].call(self)
        run_callbacks(:destroy) do
          run_callbacks(:commit) do
            if block
              block.call(self)
            else
              update_column(column, true)
            end
          end
        end
      else
        errors.add(column, default_options[:message])
        false
      end
    end
  end
end
