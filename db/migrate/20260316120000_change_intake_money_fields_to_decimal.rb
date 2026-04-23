class ChangeIntakeMoneyFieldsToDecimal < ActiveRecord::Migration[8.0]
  def up
    change_column :IntakeQuestions, :MoneyOwed, :decimal, precision: 10, scale: 2, null: false
    change_column :IntakeQuestions, :MonthlyRent, :decimal, precision: 10, scale: 2
    change_column :IntakeQuestions, :PayableToday, :decimal, precision: 10, scale: 2
  end

  def down
    change_column :IntakeQuestions, :MoneyOwed, :integer, null: false
    change_column :IntakeQuestions, :MonthlyRent, :integer
    change_column :IntakeQuestions, :PayableToday, :integer
  end
end
