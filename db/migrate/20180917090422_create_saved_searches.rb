class CreateSavedSearches < ActiveRecord::Migration[5.2]
  def change
    create_table :saved_searches do |t|
      t.references :user, foreign_key: true
      t.string :query
      t.string :name

      t.timestamps
    end
  end
end
