class Tutor < ActiveRecord::Base

  # === List of columns ===
  #   id              : integer 
  #   person_id       : integer 
  #   availability_id : integer 
  #   languages       : string 
  #   created_at      : datetime 
  #   updated_at      : datetime 
  # =======================

  belongs_to :person

  has_and_belongs_to_many :courses
  has_and_belongs_to_many :slots
  has_one :availability

  validates :person, :presence => true
  validates :availability, :presence => true
end
