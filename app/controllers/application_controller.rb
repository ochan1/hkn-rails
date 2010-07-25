class ApplicationController < ActionController::Base
  protect_from_forgery
  before_filter :get_current_user, :merge_messages
  layout 'application'

  #This is a bit of dynamic code that allows you to use methods like
  #authorize_foo to call authorize with a group as an argument. It might be
  #good to clean it up a little and put the matching in a separate class.
  # The idea comes from rails' dynamic finders.
  def respond_to?(method_id, include_private = false)
    case method_id.to_s
      when /^authorize_([_a-zA-Z]\w*)$/
        return true
      when /^check([_a-zA-Z]\w*)$/
        return true
      else
        super
    end
  end

  def method_missing(method_id, *arguments, &block)
    case method_id.to_s
      when /^authorize_([_a-zA-Z]\w*)$/
        group = $1
        self.send :authorize, group
      when /^check_([_a-zA-Z]\w*)$/
        group = $1
        self.send :check, group
      else
        super
    end
  end  
  private
  
  def get_current_user
    if UserSession.find
      @current_user = UserSession.find.person
    end
  end

  def merge_messages
    @messages ||= []
    @debug ||= []
    if flash[:notice]
      @messages << flash[:notice]
    end
  end

  def authorize(group=nil)
    if @current_user.nil?
      redirect_to :login, :notice => "Please log in to access this page."
      return
    end
    unless group.nil? or @current_user.groups.include?(Group.find_by_name("superusers")) or @current_user.groups.map{|x| x.name}.include?(group)
      redirect_to :root, :notice => "Insufficient privileges to access this page."
    end
  end

  def check(group)
    @authorizations ||= {}
    if @current_user.nil? or group.nil? or (not @current_user.groups.include?(Group.find_by_name("superusers")) and not @current_user.groups.map{|x| x.name}.include?(group))
      @authorizations[group] = false 
    else
      @authorizations[group] = true
    end
    return @authorizations[group]
  end
end
