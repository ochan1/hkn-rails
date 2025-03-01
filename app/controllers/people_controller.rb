class PeopleController < ApplicationController
  before_filter :authorize, only: [:list, :show, :edit, :update, :groups, :groups_update]
  before_filter :authorize_superuser, only: [:groups_update]
  before_filter :authorize_vp, only: [:approve, :destroy]
  before_filter :authorize_comms, only: [:groups, :contact_card]

  def list
    @category = params[:category] || "all"

    # Can view a group if:
    #   (1) you're a superuser
    #   (2) you're in it
    #   (3) it's a public group      (  vvv      one of these      vvv        )
    unless @auth['superusers'] or (%w[officers assistants cmembers members candidates all] | @current_user.groups.collect(&:name)).include?(@category)
      @messages << "No category named #{@category}. Displaying all people."
      @category = "all"
    end

    order = params[:sort] || "first_name"
    sort_direction = case params[:sort_direction]
                     when "up" then "ASC"
                     when "down" then "DESC"
                     else "ASC"
                     end

    @search_opts = {'sort' => "first_name"}.merge params
    opts = { page:     params[:page],
             per_page: params[:per_page] || 20
           }

    if %w[officers].include? @category or %w[cmembers].include? @category
      joinstr = "JOIN committeeships ON committeeships.person_id = people.id"
      cond = ["committeeships.semester = ? AND committeeships.title = ?",
        Property.semester,
        @category.singularize]
    elsif @category != "all"
      @group = Group.find_by_name(@category)
      joinstr = "JOIN groups_people ON groups_people.person_id = people.id"
      cond = ["groups_people.group_id = ?", @group.id]
    end

    # TODO: Uh is this SQL injectable?
    person_selector = Person.order("people.#{order} #{sort_direction}")
                            .joins(joinstr)
                            .where(cond)
    if @auth["vp"] and params[:not_approved]
      person_selector = person_selector.where(approved: nil)
    end

    @people = person_selector.paginate opts

    respond_to do |format|
      format.html
      format.js {
        render partial: 'list_results'
      }
    end
  end

  def search
    return if strip_params

    query = sanitize_query(params[:query])

    @results = {}

    if $SUNSPOT_ENABLED
      # Search courses
      @results[:people] = Person.search do
        unless query.blank?
          keywords query
        end
        order_by :score, :desc
      end
    else
      # Solr isn't started, hack together some results
      logger.warn "Solr isn't started, falling back to lame search"
      if $SUNSPOT_EMAIL_ENABLED
        ErrorMailer.problem_report("Solr isn't started (The only email sent until solr reactivated)").deliver
      end

      str = "%#{query}%"
      @results[:people] = FakeSearch.new

      opts = { page:     params[:page],
               per_page: params[:per_page] || 20
             }

      @results[:people].results = Person.where('first_name LIKE :search or last_name LIKE :search or username LIKE :search or email LIKE :search', search: str).paginate opts

      if Rails.env.development?
        flash[:notice] = "Solr isn't started, so your results are probably lacking."
      elsif @auth['compserv']
        flash[:notice] = "Solr isn't started."
      end
    end
    @people = @results[:people].results


  end # search

  def new
    @hide_topbar = true
    @person = Person.new
  end

  def create
    @person = Person.new(person_params)

    email_check = !@person.email.match(Person::Validation::Regex::HKNEmail).nil?

    if verify_recaptcha(message: "Captcha validation failed", model: @person) && email_check && @person.save
      # defaults to making a candidate
      @person.groups << Group.find_by_name("candidates")
      @person.groups << Group.find_by_name("candplus")

      #Create new candidate corresponding to this person
      @candidate = Candidate.new
      @candidate.person = @person
      @candidate.save

      flash[:notice] = "Account registered! Please Slack the CompServ Channel (preferred, DMs discouraged) or email CompServ to activate your account."
      redirect_to root_url
    else
      if !email_check
        @person.errors.add(:email, 'must be an HKN Gmail using the hkn.eecs domain')
      end
      render action: "new"
    end
  end

  def show
    @person = Person.find_by_username(params[:login])
    if @person == nil
      if params[:login].to_i != 0
        @person = Person.find(params[:login].to_i) #Find by id
      end
      if @person == nil
        redirect_to :root, notice: "The person you tried to view does not exist."
        return
      end
    end
    @badges = @person.badges
  end

  def edit
    if !params[:id].nil? and @current_user.in_group?("superusers")
      @person = Person.find(params[:id])
    else
      @person = @current_user
    end

    @mobile_carriers = MobileCarrier.all
  end

  def approve
    @person = Person.find(params[:id])
    @person.approved = true
    @person.save

    AccountMailer.account_approval(@person).deliver
    redirect_to action: "show"
  end

  def update
    @person = Person.find(params[:id])

    # Permissions
    if @person.id != @current_user.id and !@current_user.in_group?("superusers")
      flash[:notice] = "Could not update settings."
      redirect_to account_settings_path
    end

    # Superusers can edit anyone
    if @current_user.in_group?("superusers")
      path = edit_person_path(@person)
    else
      path = account_settings_path
    end

    # Verify password
    if params[:password][:current]
      if @current_user.valid_password?(params[:password][:current])
        params[:person][:password] = params[:password][:new]
        params[:person][:password_confirmation] = params[:password][:confirm]
      else
        redirect_to(path, notice: "You must enter in your current password to make any changes.")
        return
      end
    end

    # DO IT
    if @person.update_attributes(person_params)
      redirect_to(path, notice: 'Settings successfully updated.')
    else
      redirect_to(path, notice: 'Settings could not be updated.')
    end
  end

  def destroy
    @person = Person.find(params[:id])

    if (@auth['vp'] && not(@person.approved)) || @auth['superuser']
      @person.destroy
      flash[:notice] = %(Deleted "#{@person.fullname}".)
    else
      flash[:notice] = "You do not have the authorization to do that."
    end

    redirect_to people_list_path
  end

  def groups
    @person = (Person.find(params[:id]) rescue nil) || (Person.find_by_username(params[:id]) rescue nil)
    unless @person
      flash[:notice] = "Invalid id #{params[:id]}"
      return redirect_to people_list_path
    end
    @allow_edit = can_edit_profile?(@person)
  end

  def groups_update
    unless @person = Person.find(params[:id])
      flash[:notice] = "Invalid id #{params[:id]}"
      return redirect_to people_list_path
    end

    params[:groups] ||= ""
    errors = []
    @person.groups = []
    params[:groups].split.each do |group|
      group.downcase!
      unless group = Group.find_by_name(group)
        errors << "bad group #{group}"
      end
      @person.groups.push(group)
    end

    if errors.empty? and @person.save
      flash[:notice] = "ok"
    else
      flash[:notice] = "Error #{errors.join(', ').inspect}"
    end

    render action: :groups
  end

  def contact_card
    comms = Person.joins(:committeeships)
      .where("committeeships.semester" => Property.semester)
      .where("committeeships.title IN (?)", ["officer", "assistant", "cmember"])

    csv_string = CSV.generate do |csv|
      csv << ['First Name', 'Last Name', 'Email Address', 'Mobile Phone']

      comms.each do |person|
        csv << [:first_name, :last_name, :email, :phone_number]
          .collect{ |s| person.send(s) }
      end
    end

    send_data csv_string,
              type: 'text/csv',
              disposition: "attachment",
              filename: "hkn-contacts.csv"
  end

  private
  def can_edit_profile?(person)
    # @current_user can view @person if:
    #   1) they're the same person
    #   2) @current_user is a superuser
    @current_user && @current_user.id == params[:id] or @auth['superusers']
  end

  def person_params
    params.require(:person).permit(
      :first_name,
      :last_name,
      :username,
      :email,
      :phone_number,
      :aim,
      :date_of_birth,
      :picture,
      :private,
      :local_address,
      :perm_address,
      :grad_semester,
      :sms_alerts,
      :mobile_carrier_id,
      :password,
      :password_confirmation
    )
  end
end
