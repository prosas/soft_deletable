# Soft_Deletable
Soft delete implementation for Rails app.

# Usage
Install gem:
```sh
 gem 'soft_deletable', git: "https://github.com/prosas/soft_deletable"
```
```ruby
class MyModel < ApplicationRecord
	extend SoftDeletable

	soft_destroy :removed # Boolean column that defines whether the record was removed or not.
end

@model = MyModel.find(id)
@model.destroy
MyModel.find(@model.id)
# >> ActiveRecord::RecordNotFound
```
# Callbacks
Rails callbacks will trigger normally.
```ruby
class MyModel < ApplicationRecord
	extend SoftDeletable
	before_destroy do
		puts "...will be destroyed"
	end
	after_destroy do
		puts "destroyed!"
	end
	soft_destroy :removed
end

MyModel.first.destroy
# >> ...will be destroyed
# >> destroyed!
```

# Conditional
You can define a validation for the **soft_destroy** method.
```ruby
#...
 soft_destroy :removed, if: ->(instance){ instance.can_remove? }, message: 'Don`t do this.'
#...
```
# Force destroy
When `force_destroy` is exactly `true`, the `if` condition is skipped and the record is destroyed anyway. Any other value still respects `if`.

The same flag is forwarded to `dependent: :destroy` associations, so they also skip their `if` conditions during the cascade.
```ruby
soft_destroy :removed, if: ->(instance){ instance.can_remove? }

@model.destroy                    # respects `if`
@model.destroy(force_destroy: true) # ignores `if` and forces the destroy (including dependents)
```
# Custom function
Allow you to define your own implementation.
```ruby
#...
 soft_destroy :removed do |instance|
 	# additional things
 	instance.update_column(removed: true, updated_at: Time.now)
 end
#...
```
