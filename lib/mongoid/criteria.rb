# encoding: utf-8
require "mongoid/criterion/exclusion"
require "mongoid/criterion/inclusion"
require "mongoid/criterion/inspection"
require "mongoid/criterion/optional"
require "mongoid/criterion/scoping"

module Mongoid #:nodoc:

  # The +Criteria+ class is the core object needed in Mongoid to retrieve
  # objects from the database. It is a DSL that essentially sets up the
  # selector and options arguments that get passed on to a Mongo::Collection
  # in the Ruby driver. Each method on the +Criteria+ returns self to they
  # can be chained in order to create a readable criterion to be executed
  # against the database.
  #
  # @example Create and execute a criteria.
  #   criteria = Criteria.new
  #   criteria.only(:field).where(:field => "value").skip(20).limit(20)
  #   criteria.execute
  class Criteria
    include Enumerable
    include Origin::Queryable
    include Criterion::Exclusion
    include Criterion::Inclusion
    include Criterion::Inspection
    include Criterion::Optional
    include Criterion::Scoping

    attr_accessor :embedded, :klass

    delegate \
      :add_to_set,
      :aggregate,
      :avg,
      :blank?,
      :count,
      :size,
      :length,
      :delete,
      :delete_all,
      :destroy,
      :destroy_all,
      :distinct,
      :empty?,
      :execute,
      :first,
      :group,
      :last,
      :max,
      :min,
      :one,
      :pull,
      :shift,
      :sum,
      :update,
      :update_all, to: :context

    # Concatinate the criteria with another enumerable. If the other is a
    # +Criteria+ then it needs to get the collection from it.
    #
    # @example Concat 2 criteria.
    #   criteria + criteria
    #
    # @param [ Criteria ] other The other criteria.
    def +(other)
      entries + comparable(other)
    end

    # Returns the difference between the criteria and another enumerable. If
    # the other is a +Criteria+ then it needs to get the collection from it.
    #
    # @example Get the difference of 2 criteria.
    #   criteria - criteria
    #
    # @param [ Criteria ] other The other criteria.
    def -(other)
      entries - comparable(other)
    end

    # Returns true if the supplied +Enumerable+ or +Criteria+ is equal to the results
    # of this +Criteria+ or the criteria itself.
    #
    # @note This will force a database load when called if an enumerable is passed.
    #
    # @param [ Object ] other The other +Enumerable+ or +Criteria+ to compare to.
    #
    # @return [ true, false ] If the objects are equal.
    def ==(other)
      case other
      when Criteria
        self.selector == other.selector && self.options == other.options
      when Enumerable
        return (execute.entries == other)
      else
        return false
      end
    end

    # Build a document given the selector and return it.
    # Complex criteria, such as $in and $or operations will get ignored.
    #
    # @example build the document.
    #   Person.where(:title => "Sir").build
    #
    # @example Build with selectors getting ignored.
    #   Person.where(:age.gt => 5).build
    #
    # @return [ Document ] A non-persisted document.
    #
    # @since 2.0.0
    def build(attrs = {})
      create_document(:new, attrs)
    end

    # Get the collection associated with the criteria.
    #
    # @example Get the collection.
    #   criteria.collection
    #
    # @return [ Collection ] The collection.
    #
    # @since 2.2.0
    def collection
      klass.collection
    end

    # Return or create the context in which this criteria should be executed.
    #
    # This will return an Enumerable context if the class is embedded,
    # otherwise it will return a Mongo context for root classes.
    #
    # @example Get the appropriate context.
    #   criteria.context
    #
    # @return [ Mongo, Enumerable ] The appropriate context.
    def context
      @context ||= Contexts.context_for(self, embedded)
    end

    # Create a document in the database given the selector and return it.
    # Complex criteria, such as $in and $or operations will get ignored.
    #
    # @example Create the document.
    #   Person.where(:title => "Sir").create
    #
    # @example Create with selectors getting ignored.
    #   Person.where(:age.gt => 5).create
    #
    # @return [ Document ] A newly created document.
    #
    # @since 2.0.0.rc.1
    def create(attrs = {})
      create_document(:create, attrs)
    end

    def documents
      @documents ||= []
    end

    def documents=(docs)
      @documents = docs
    end

    # Iterate over each +Document+ in the results. This can take an optional
    # block to pass to each argument in the results.
    #
    # @example Iterate over the criteria results.
    #   criteria.each { |doc| p doc }
    #
    # @return [ Criteria ] The criteria itself.
    def each(&block)
      tap { context.iterate(&block) }
    end

    # Return true if the criteria has some Document or not.
    #
    # @example Are there any documents for the criteria?
    #   criteria.exists?
    #
    # @return [ true, false ] If documents match.
    def exists?
      context.count > 0
    end

    # Run an explain on the criteria.
    #
    # @example Explain the criteria.
    #   Band.where(name: "Depeche Mode").explain
    #
    # @return [ Hash ] The explain result.
    #
    # @since 3.0.0
    def explain
      driver.find(selector, options).explain
    end

    # Extract a single id from the provided criteria. Could be in an $and
    # query or a straight _id query.
    #
    # @example Extract the id.
    #   criteria.extract_id
    #
    # @return [ Object ] The id.
    #
    # @since 2.3.0
    def extract_id
      selector["_id"]
    end

    # When freezing a criteria we need to initialize the context first
    # otherwise the setting of the context on attempted iteration will raise a
    # runtime error.
    #
    # @example Freeze the criteria.
    #   criteria.freeze
    #
    # @return [ Criteria ] The frozen criteria.
    #
    # @since 2.0.0
    def freeze
      context and inclusions and super
    end

    def initialize(klass)
      @klass = klass
      super(klass.aliased_fields, klass.fields)
    end

    # Merges another object with this +Criteria+ and returns a new criteria.
    # The other object may be a +Criteria+ or a +Hash+. This is used to
    # combine multiple scopes together, where a chained scope situation
    # may be desired.
    #
    # @example Merge the criteria with another criteria.
    #   criteri.merge(other_criteria)
    #
    # @param [ Criteria ] other The other criterion to merge with.
    #
    # @return [ Criteria ] A cloned self.
    def merge(other)
      clone.tap do |criteria|
        criteria.merge!(other)
      end
    end

    # Merge the other criteria into this one.
    #
    # @example Merge another criteria into this criteria.
    #   criteria.merge(Person.where(name: "bob"))
    #
    # @param [ Criteria ] other The criteria to merge in.
    #
    # @return [ Criteria ] The merged criteria.
    #
    # @since 3.0.0
    def merge!(other)
      criteria = other.to_criteria
      tap do |crit|
        crit.selector.update(criteria.selector)
        crit.options.update(criteria.options)
        crit.documents = criteria.documents.dup if criteria.documents.any?
        crit.scoping_options = criteria.scoping_options
        crit.inclusions = (crit.inclusions + criteria.inclusions.dup).uniq
      end
    end

    # Returns true if criteria responds to the given method.
    #
    # @example Does the criteria respond to the method?
    #   crtiteria.respond_to?(:each)
    #
    # @param [ Symbol ] name The name of the class method on the +Document+.
    # @param [ true, false ] include_private Whether to include privates.
    #
    # @return [ true, false ] If the criteria responds to the method.
    def respond_to?(name, include_private = false)
      # don't include klass private methods because method_missing won't call them
      super || klass.respond_to?(name) || entries.respond_to?(name, include_private)
    end

    alias :to_ary :to_a

    # Needed to properly get a criteria back as json
    #
    # @example Get the criteria as json.
    #   Person.where(:title => "Sir").as_json
    #
    # @param [ Hash ] options Options to pass through to the serializer.
    #
    # @return [ String ] The JSON string.
    def as_json(options = nil)
      entries.as_json(options)
    end

    # Convenience method of raising an invalid options error.
    #
    # @example Raise the error.
    #   criteria.raise_invalid
    #
    # @raise [ Errors::InvalidOptions ] The error.
    #
    # @since 2.0.0
    def raise_invalid
      raise Errors::InvalidFind.new
    end

    # Convenience for objects that want to be merged into a criteria.
    #
    # @example Convert to a criteria.
    #   criteria.to_criteria
    #
    # @return [ Criteria ] self.
    #
    # @since 3.0.0
    def to_criteria
      self
    end

    # Convert the criteria to a proc.
    #
    # @example Convert the criteria to a proc.
    #   criteria.to_proc
    #
    # @return [ Proc ] The wrapped criteria.
    #
    # @since 3.0.0
    def to_proc
      ->{ self }
    end

    protected

    # Return the entries of the other criteria or the object. Used for
    # comparing criteria or an enumerable.
    #
    # @example Get the comparable version.
    #   criteria.comparable(other)
    #
    # @param [ Criteria ] other Another criteria.
    #
    # @return [ Array ] The array to compare with.
    def comparable(other)
      other.is_a?(Criteria) ? other.entries : other
    end

    # Get the raw driver collection from the criteria.
    #
    # @example Get the raw driver collection.
    #   criteria.driver
    #
    # @return [ Mongo::Collection ] The driver collection.
    #
    # @since 2.2.0
    def driver
      collection.driver
    end

    # Clone or dup the current +Criteria+. This will return a new criteria with
    # the selector, options, klass, embedded options, etc intact.
    #
    # @example Clone a criteria.
    #   criteria.clone
    #
    # @example Dup a criteria.
    #   criteria.dup
    #
    # @param [ Criteria ] other The criteria getting cloned.
    #
    # @return [ nil ] nil.
    def initialize_copy(other)
      @selector = other.selector.dup
      @options = other.options.dup
      @includes = other.inclusions.dup
      @scoping_options = other.scoping_options
      @documents = other.documents.dup
      @context = nil
    end

    # Used for chaining +Criteria+ scopes together in the for of class methods
    # on the +Document+ the criteria is for.
    def method_missing(name, *args, &block)
      if klass.respond_to?(name)
        klass.send(:with_scope, self) do
          klass.send(name, *args, &block)
        end
      else
        return entries.send(name, *args)
      end
    end

    private

    # Create a document given the provided method and attributes from the
    # existing selector.
    #
    # @api private
    #
    # @example Create a new document.
    #   criteria.create_document(:new, {})
    #
    # @param [ Symbol ] method Either :new or :create.
    # @param [ Hash ] attrs Additional attributes to use.
    #
    # @return [ Document ] The new or saved document.
    #
    # @since 3.0.0
    def create_document(method, attrs = {})
      klass.__send__(method,
        selector.inject(attrs) do |hash, (key, value)|
          hash.tap do |_attrs|
            unless key.to_s =~ /\$/ || value.is_a?(Hash)
              _attrs[key] = value
            end
          end
        end
      )
    end
  end
end
