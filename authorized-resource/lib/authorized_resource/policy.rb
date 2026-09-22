# frozen_string_literal: true

module AuthorizedModel
  Target = Data.define(:scope_type, :scope_id, :capability) do
    def initialize(scope_type:, scope_id:, capability:)
      super(
        scope_type: scope_type.to_s.freeze,
        scope_id: scope_id.to_s.freeze,
        capability: capability.to_s.freeze
      )
    end
  end

  Requirement = Data.define(:capability, :scope_type, :resolver) do
    def targets(record)
      Array(resolver.call(record)).filter_map do |scope_id|
        next if scope_id.nil? || scope_id.to_s.empty?

        Target.new(scope_type: scope_type, scope_id: scope_id, capability: capability)
      end
    end
  end

  class Policy
    attr_reader :read_requirements, :modify_requirements, :iam_readers, :iam_modifiers

    def initialize(read_requirements: [], modify_requirements: [], iam_readers: [], iam_modifiers: [], read_only: false)
      @read_requirements = read_requirements.freeze
      @modify_requirements = modify_requirements.freeze
      @iam_readers = iam_readers.map(&:to_s).freeze
      @iam_modifiers = iam_modifiers.map(&:to_s).freeze
      @read_only = read_only
      freeze
    end

    def with_requirement(kind, requirement, iam:)
      attrs = to_h
      attrs.fetch("#{kind}_requirements".to_sym) << requirement
      attrs.fetch("iam_#{kind == :read ? 'readers' : 'modifiers'}".to_sym).concat(Array(iam).map(&:to_s))
      self.class.new(**attrs)
    end

    def read_only(iam:)
      self.class.new(**to_h.merge(read_only: true, iam_readers: (iam_readers + Array(iam).map(&:to_s)).uniq))
    end

    def with_iam(kind, identities)
      attrs = to_h
      key = kind == :read ? :iam_readers : :iam_modifiers
      attrs[key] = (attrs.fetch(key) + Array(identities).map(&:to_s)).uniq
      self.class.new(**attrs)
    end

    def read_only?
      @read_only
    end

    def configured_for?(kind)
      kind == :read ? (read_requirements.any? || iam_readers.any?) : (modify_requirements.any? || iam_modifiers.any? || read_only?)
    end

    private

    def to_h
      {
        read_requirements: read_requirements.dup,
        modify_requirements: modify_requirements.dup,
        iam_readers: iam_readers.dup,
        iam_modifiers: iam_modifiers.dup,
        read_only: read_only?
      }
    end
  end
end
