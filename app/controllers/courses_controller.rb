require 'csv'
require 'course_spreadsheet'

class CoursesController < ApplicationController
  layout 'course'

  before_action :find_course, except: [:index, :new, :create]
  before_action :require_current_user, except: [:public]
  before_action :require_registered_user, except: [:public, :index, :new, :create]
  before_action :require_admin_or_prof, except: [:index, :new, :show, :public, :withdraw]

  def index
    @courses_by_term = Course.order(:name).group_by(&:term)

    # We can't use the course layout if we don't have a @course.
    render layout: 'application'
  end

  def show
    if current_user_staff_for?(@course)
      @pending_grading = @course.pending_grading
   else
      @pending_grading = {}
    end
    # elsif @registration.staff?
    #   @pending_grading = []
    #   @assignments = []
    @allocated_grading = @course.grading_assigned_for(current_user)
    @completed_grading = @course.grading_done_for(current_user)
    @assignments = Assignment
                   .where(id: @pending_grading.keys + @allocated_grading.keys + @completed_grading.keys)
                   .map{|a| [a.id, a]}.to_h

    if current_user_prof_for?(@course)
      @abnormals = @course.abnormal_subs
      @assns = @course.assignments_sorted
      @unpublished = @course.unpublished_grades
    end
    @teams = multi_group_by(current_user.teams.includes(:users).order(end_date: :desc, id: :asc),
                            [:course_id, :teamset_id])
  end

  def new
    @course = Course.new
    @course.lateness_config = LatenessConfig.default
    @course.sections = [Section.new(instructor: current_user)]
    render :new, layout: 'application'
  end

  def edit
  end

  def facebook
    unless current_user_site_admin? || current_user_staff_for?(@course)
      redirect_back fallback_location: root_path, alert: "Must be an admin or professor."
      return
    end
    @students = @course.students
                .select("users.*", "registrations.dropped_date", "registrations.section_id")
                .order("users.last_name", "users.first_name")
  end

  def create
    @course = Course.new(course_params)

    if @course.save
      redirect_to course_path(@course), notice: 'Course was successfully created.'
    else
      render :new, layout: 'application'
    end
  end

  def update
    @course.assign_attributes(course_params)

    if @course.save
      redirect_to course_path(@course), notice: 'Course was successfully updated.'
    else
      render :edit
    end
  end

  # def destroy
  #   @course.destroy
  #   redirect_to courses_path
  # end

  def public
    @course = Course.find_by(id: params[:id])

    if @course.nil?
      redirect_to root_path, alert: "No such course or that material is not public."
      return
    end
    if current_user
      redirect_to course_path(@course)
      return
    end

    unless @course.public?
      redirect_to root_path, alert: "No such course or that material is not public."
      return
    end
  end

  def withdraw
    @course = Course.find_by(id: params[:id])

    reg = current_user.registration_for(@course)
    if reg.nil?
      redirect_to course_path(@course), alert: "You cannot withdraw from a course you aren't registered for."
      return
    elsif reg.dropped_date
      redirect_to course_path(@course), alert: "You have already withdrawn from this course."
      return
    elsif reg.role == "professor" && @course.professors.count == 1
      redirect_to course_path(@course), alert: "You cannot withdraw from the course: you are the only instructor for it."
      return
    end
    reg.dropped_date = DateTime.now
    reg.show_in_lists = false
    reg.save!
    current_user.disconnect(@course)
    redirect_to root_path, notice: "You have successfully withdrawn from #{@course.name}"
  end

  def gradesheet
    @all_course_info = all_course_info
    respond_to do |format|
      #      format.csv { send_data @all_course_info.to_csv(col_sep: "\t") }
      format.xlsx { send_data @all_course_info.to_xlsx, type: "application/xlsx" }
    end
  end

  protected

  def all_course_info
    CourseSpreadsheet.new(@course)
  end

  def course_params
    params[:course].permit(:name, :footer, :total_late_days, :private,
                           :public, :sections, :term_id, :sub_max_size,
                           :lateness_config_id,
                           lateness_config_attributes: [
                             :type, :percent_off, :frequency,
                             :max_penalty, :days_per_assignment,
                             :id, :_destroy
                           ],
                           sections_attributes: [
                             :course_id, :crn, :meeting_time, :instructor_id,
                             :id, :prof_name, :_destroy
                           ])
  end
end
