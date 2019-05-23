require 'activerecord-import'
require_relative 'issue_reader'

module OpenProject::Bcf::BcfXml
  class Importer
    attr_reader :file, :project, :current_user, :instance_cache

    def initialize(file, project, current_user:)
      @file = file
      @project = project
      @current_user = current_user

      @instance_cache = {}
    end

    ##
    # Get a list of issues contained in a BCF
    # but do not perform the import
    def get_extractor_list
      @extractor_list ||= Zip::File.open(@file) do |zip|
        yield_markup_bcf_files(zip)
          .map do |entry|
          to_listing(MarkupExtractor.new(entry))
        end
      end
    end

    def all_people
      @instance_cache[:all_people] ||= get_extractor_list.map { |entry| entry[:people] }.flatten.uniq
    end

    def all_mails
      @instance_cache[:all_mails] ||= get_extractor_list.map { |entry| entry[:mail_addresses] }.flatten.uniq
    end

    def known_users
      @instance_cache[:known_users] ||= User.where(mail: all_mails).includes(:memberships)
    end

    def unknown_mails
      @instance_cache[:unknown_mails] ||= all_mails.map(&:downcase) - known_users.map(&:mail).map(&:downcase)
    end

    def members
      @instance_cache[:members] ||= known_users.select { |user| user.projects.map(&:id).include? @project.id }
    end

    def non_members
      @instance_cache[:non_members] ||= known_users - members
    end

    def invalid_people
      @instance_cache[:invalid_people] ||= all_people - all_mails
    end

    def import!(options = {})
      Zip::File.open(@file) do |zip|
        treat_unknown_mails(options)
        clear_instance_cache

        # Extract all topics of the zip and save them
        synchronize_topics(zip)

        # TODO: Extract documents

        # TODO: Extract BIM snippets
      end
    rescue StandardError => e
      Rails.logger.error "Failed to import BCF Zip #{file}: #{e} #{e.message}"
      Rails.logger.debug { e.backtrace.join("\n") }
      raise
    end

    private

    ##
    # Invite all unknown email addresses and add them
    def treat_unknown_mails(options)
      if options[:unknown_mails_action] == 'invite' && options[:unknown_mails_invite_role_ids].any?
        if User.current.admin?
          if enterprise_allow_new_users?
            unknown_mails.each do |mail|
              user = UserInvitation.invite_new_user(email: mail)
              member = Member.create(user: user, project: project)
              membership_service = ::Members::EditMembershipService.new(member, save: true, current_user: User.current)
              membership_service.call(attributes: {role_ids: options[:unknown_mails_invite_role_ids]})
            end
          else
            raise StandardError.new 'Enterprise Edition user limit reached.'
          end
        else
          raise StandardError.new 'For inviting new users you need admin privileges.'
        end
      end

    end

    def to_listing(extractor)
      keys = %i[uuid title priority status description author assignee modified_author due_date]
      Hash[keys.map { |k| [k, extractor.public_send(k)] }].tap do |attributes|
        attributes[:viewpoint_count] = extractor.viewpoints.count
        attributes[:comments_count] = extractor.comments.count
        attributes[:people] = extractor.people
        attributes[:mail_addresses] = extractor.mail_addresses
      end
    end

    def synchronize_topics(zip)
      yield_markup_bcf_files(zip)
        .map do |entry|
          issue = IssueReader.new(project, zip, entry, current_user: current_user).extract!
          if issue.errors.blank?
            issue.save
          end
          issue
        end
    end

    ##
    # Yields topic bcf files (that contain topic entries and their uuid) from the ZIP files
    # while skipping all other entries
    def yield_markup_bcf_files(zip)
      zip.select { |entry| entry.name.end_with?('markup.bcf') }
    end

    def enterprise_allow_new_users?
      !OpenProject::Enterprise.user_limit_reached? || !OpenProject::Enterprise.fail_fast?
    end

    def clear_instance_cache
      @instance_cache = {}
    end
  end
end
