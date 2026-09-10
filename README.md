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

The flag is stored in `SoftDeletable::Current` with the key `id_nome_da_classe`. When a child is destroyed through `dependent: :destroy`, `destroyed_by_association` is used to read the parent's `force_destroy` from that state and apply it to the child.
```ruby
soft_destroy :removed, if: ->(instance){ instance.can_remove? }

@model.destroy                    # respects `if`
@model.destroy(force_destroy: true) # ignores `if` and forces the destroy (including dependents)
```
# Destroy metadata
By default, `destroy` also fills:
- `deleted_at` (`deleted_at_column`) with the deletion timestamp
- `identify_destroy` (`indentify_destroy_column`) with a unique UUID for that deletion

When a record is destroyed through `dependent: :destroy`, `destroyed_by_association` is used to detect that cascade. The child then reuses the parent's `indentify_destroy_column` value, looked up from `SoftDeletable::Current` with the key `id_nome_da_classe` (for example `"123_Parent"`).

```ruby
soft_destroy :removed,
             deleted_at_column: :removed_at,
             indentify_destroy_column: :removal_id
```

# Recover
Call `recover` to restore a soft-deleted record. The gem then restores `has_many`/`has_one` children with `dependent: :destroy` that also implement `soft_destroy` and share the same `indentify_destroy_column` value. Associations without `dependent: :destroy` or without `soft_destroy` are left untouched.

The whole restore (record and matching children) runs inside a transaction. If a child recover fails, nothing is committed.

Do not override `recover`. Custom restore logic goes in the `recover:` option; the gem still walks the matching associations afterward.

By default, `recover` sets the boolean column to `false` and clears `deleted_at_column` and `indentify_destroy_column`.
```ruby
soft_destroy :removed,
             recover: ->(instance) { instance.update_columns(removed: false, removed_at: nil, removal_id: nil) }
```
```ruby
@model.destroy
@model.recover
```

# Custom function
Allow you to define your own implementation.

Before the block runs, the gem fills `deleted_at_column` and `indentify_destroy_column`. After the block, it reloads the record and raises `SoftDeletable::MissingDestroyAttribute` if either value is blank. The whole destroy runs inside a transaction, so a missing value rolls back the deletion.
```ruby
#...
 soft_destroy :removed do |instance|
 	# additional things
 	instance.update_column(removed: true, updated_at: Time.now)
 end
#...
```
