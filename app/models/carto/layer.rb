require 'active_record'
require_relative './carto_json_serializer'
require_dependency 'carto/table_utils'

module Carto
  module LayerTableDependencies
    def affected_tables
      return [] unless maps.first.present? && options.present?
      node_id = options.symbolize_keys[:source]
      if node_id.present?
        visualization_id = map.visualization.id
        node = AnalysisNode.find_by_natural_id(visualization_id, node_id)
        return [] unless node
        dependencies = node.source_descendants.map do |source_node|
          tables_by_query = tables_from_query(source_node.params[:query])
          table_name = source_node.options[:table_name]
          tables_by_name = table_name ? tables_from_names([table_name], user) : []

          tables_by_query + tables_by_name
        end
        dependencies.flatten.compact.uniq
      else
        (tables_from_query_option + tables_from_table_name_option).compact.uniq
      end
    end

    def tables_from_query_option
      tables_from_query(query)
    end

    def tables_from_query(query)
      query.present? ? tables_from_names(affected_table_names(query), user) : []
    rescue => e
      # INFO: this covers changes that CartoDB can't track.
      # For example, if layer SQL contains wrong SQL (uses a table that doesn't exist, or uses an invalid operator).
      CartoDB::Logger.debug(message: 'Could not retrieve tables from query', exception: e, user: user, layer: self)
      []
    end

    def tables_from_table_name_option
      return [] if options.empty?
      sym_options = options.symbolize_keys
      user_name = sym_options[:user_name]
      table_name = sym_options[:table_name]
      schema_prefix = user_name.present? && table_name.present? && !table_name.include?('.') ? %{"#{user_name}".} : ''
      tables_from_names(["#{schema_prefix}#{table_name}"], user)
    end
  end

  class Layer < ActiveRecord::Base
    include Carto::TableUtils
    include LayerTableDependencies

    serialize :options, CartoJsonSerializer
    serialize :infowindow, CartoJsonSerializer
    serialize :tooltip, CartoJsonSerializer

    has_many :layers_maps
    has_many :maps, through: :layers_maps

    has_many :layers_user
    has_many :users, through: :layers_user

    has_many :layers_user_table
    has_many :user_tables, through: :layers_user_table, class_name: Carto::UserTable

    has_many :widgets, class_name: Carto::Widget, order: '"order"'

    TEMPLATES_MAP = {
      'table/views/infowindow_light' =>               'infowindow_light',
      'table/views/infowindow_dark' =>                'infowindow_dark',
      'table/views/infowindow_light_header_blue' =>   'infowindow_light_header_blue',
      'table/views/infowindow_light_header_yellow' => 'infowindow_light_header_yellow',
      'table/views/infowindow_light_header_orange' => 'infowindow_light_header_orange',
      'table/views/infowindow_light_header_green' =>  'infowindow_light_header_green',
      'table/views/infowindow_header_with_image' =>   'infowindow_header_with_image'
    }.freeze

    def affected_tables_readable_by(user)
      affected_tables.select { |ut| ut.readable_by?(user) }
    end

    def data_readable_by?(user)
      affected_tables.all? { |ut| ut.readable_by?(user) }
    end

    def legend
      @legend ||= options['legend']
    end

    def qualified_table_name(schema_owner_user = nil)
      table_name = options['table_name']
      if table_name.present? && table_name.include?('.')
        table_name
      else
        schema_prefix = schema_owner_user.nil? ? '' : "#{schema_owner_user.sql_safe_database_schema}."
        "#{schema_prefix}#{safe_table_name_quoting(options['table_name'])}"
      end
    end

    # INFO: for vizjson v3 this is not used, see VizJSON3LayerPresenter#to_vizjson_v3
    def infowindow_template_path
      if self.infowindow.present? && self.infowindow['template_name'].present?
        template_name = TEMPLATES_MAP.fetch(self.infowindow['template_name'], self.infowindow['template_name'])
        Rails.root.join("lib/assets/javascripts/cartodb/table/views/infowindow/templates/#{template_name}.jst.mustache")
      else
        nil
      end
    end

    # INFO: for vizjson v3 this is not used, see VizJSON3LayerPresenter#to_vizjson_v3
    def tooltip_template_path
      if self.tooltip.present? && self.tooltip['template_name'].present?
        template_name = TEMPLATES_MAP.fetch(self.tooltip['template_name'], self.tooltip['template_name'])
        Rails.root.join("lib/assets/javascripts/cartodb/table/views/tooltip/templates/#{template_name}.jst.mustache")
      else
        nil
      end
    end

    def basemap?
      gmapsbase? || tiled?
    end

    def base?
      tiled? || background? || gmapsbase? || wms?
    end

    def torque?
      kind == 'torque'
    end

    def data_layer?
      !base?
    end

    def user_layer?
      tiled? || background? || gmapsbase? || wms?
    end

    def named_map_layer?
      tiled? || background? || gmapsbase? || wms? || carto?
    end

    def carto?
      kind == 'carto'
    end

    def tiled?
      kind == 'tiled'
    end

    def background?
      kind == 'background'
    end

    def gmapsbase?
      kind == 'gmapsbase'
    end

    def wms?
      kind == 'wms'
    end

    def supports_labels_layer?
      basemap? && options["labels"] && options["labels"]["url"]
    end

    def map
      maps.first
    end

    def visualization
      map.visualization
    end

    def user
      @user ||= map.nil? ? nil : map.user
    end

    def wrapped_sql(user)
      query_wrapper = options.symbolize_keys[:query_wrapper]
      sql = default_query(user)
      if query_wrapper.present? && torque?
        query_wrapper.gsub('<%= sql %>', sql)
      else
        sql
      end
    end

    def default_query(user = nil)
      sym_options = options.symbolize_keys
      query = sym_options[:query]

      if query.present?
        query
      else
        user_username = user.nil? ? nil : user.username
        user_name = sym_options[:user_name]
        table_name = sym_options[:table_name]

        if table_name.present? && !table_name.include?('.') && user_name.present? && user_username != user_name
          %{ select * from "#{user_name}".#{safe_table_name_quoting(table_name)} }
        else
          "SELECT * FROM #{qualified_table_name}"
        end
      end
    end

    def register_table_dependencies
      self.user_tables = affected_tables if data_layer?
    end

    private

    def tables_from_names(table_names, user)
      ::Table.get_all_user_tables_by_names(table_names, user)
    end

    def affected_table_names(query)
      return [] unless query.present?

      # TODO: This is the same that CartoDB::SqlParser().affected_tables does. Maybe remove that class?
      query_tables = user.in_database.execute("SELECT CDB_QueryTables(#{user.in_database.quote(query)})").first
      query_tables['cdb_querytables'].split(',').map { |table_name|
        t = table_name.gsub!(/[\{\}]/, '')
        (t.blank? ? nil : t)
      }.compact.uniq
    end

    def query
      options.symbolize_keys[:query]
    end
  end
end