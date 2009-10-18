# This class represents a value inside of attribute part of package meta data

class AttribValue < ActiveRecord::Base
  acts_as_list :scope => :attrib
  belongs_to :attrib
end
