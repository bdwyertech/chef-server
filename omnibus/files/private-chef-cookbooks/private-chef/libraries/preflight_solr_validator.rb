#
# Copyright:: 2015-2018 Chef Software, Inc.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

require_relative './preflight_checks.rb'

class SolrPreflightValidator < PreflightValidator
  # The cs_*attr variables hold the user-defined configuration
  attr_reader :cs_solr_attr, :cs_erchef_attr,
              :cs_elasticsearch_attr, :cs_rabbitmq_attr,
              :cs_opscode_expander_attr

  # The node_*attr variables hold the default configuration
  attr_reader :node_solr_attr, :node_elasticsearch_attr, :node_erchef_attr

  def initialize(node)
    super

    @cs_solr_attr = PrivateChef['opscode_solr4']
    @cs_erchef_attr = PrivateChef['opscode_erchef']
    @cs_elasticsearch_attr = PrivateChef['elasticsearch']
    @cs_rabbitmq_attr = PrivateChef['rabbitmq']
    @cs_opscode_expander_attr = PrivateChef['opscode_expander']

    @node_erchef_attr = node['private_chef']['opscode-erchef']
    @node_solr_attr = node['private_chef']['opscode-solr4']
    @node_elasticsearch_attr = node['private_chef']['elasticsearch']
  end

  def run!
    verify_one_search_provider
    verify_es_disabled_if_user_set_external_solr
    verify_unused_services_are_disabled_if_using_internal_es

    warn_unchanged_external_flag
    verify_external_url
    verify_erchef_config
  end

  def verify_one_search_provider
    if elasticsearch_enabled? && solr_enabled?
      fail_with err_SOLR002_failed_validation
    end
  end

  # If an external search provider (ES or Solr) was explicitly enabled
  # by the user, then we expect that both internal search services
  # should be disabled.
  def verify_es_disabled_if_user_set_external_solr
    # NOTE(ssd) 2020-05-13: This might impact the people who we gave
    # pre-release access to.
    if cs_solr_attr['external'] && elasticsearch_enabled?
      fail_with err_SOLR003_failed_validation
    end

    if solr_enabled? && external?
      fail_with err_SOLR004_failed_validation
    end
  end

  # The user might have a combination of solr, rabbitmq or
  # opscode-expander explicitly enabled in their config.
  #
  # If we are using the new internal elasticsearch, this is an
  # unsupported configuration.
  #
  def verify_unused_services_are_disabled_if_using_internal_es
    if elasticsearch_enabled?
      msg = []
      if cs_solr_attr['enable']
        msg << err_SOLR005_failed_validation
      end

      if cs_rabbitmq_attr['enable']
        msg << err_SOLR006_failed_validation
      end

      if cs_opscode_expander_attr['enable']
        msg << err_SOLR007_failed_validation
      end
      unless msg.empty?
        fail_with msg.join("\n")
      end
    end
  end

  def external?
    cs_elasticsearch_attr['external'] || cs_solr_attr['external']
  end

  def elasticsearch_enabled?
    # TODO(ssd) 2020-05-13: This currently lives in another PR, but to
    # facilitate updates for chef-backend users without a
    # configuration change, we are going to explicitly set
    # elasticsearch to disabled at runtime.
    return false if PrivateChef['use_chef_backend']

    if cs_elasticsearch_attr['enable'].nil?
      node_elasticsearch_attr['enable']
    else
      cs_elasticsearch_attr['enable']
    end
  end

  def solr_enabled?
    if cs_solr_attr['enable'].nil?
      node_solr_attr['enable']
    else
      cs_solr_attr['enable']
    end
  end

  def warn_unchanged_external_flag
    if OmnibusHelper.has_been_bootstrapped? && backend? && previous_run
      # ES configuration is preferred everywhere so we check that first
      previous_external_setting = if previous_run['elasticsearch'].key?('external')
                                    previous_run['elasticsearch']['external']
                                  elsif previous_run['opscode-solr4'].key?('external')
                                    previous_run['opscode-solr4']['external']
                                  else
                                    # The default external setting has
                                    # always been a falsy value except
                                    # for a couple of commits that
                                    # never went out.
                                    false
                                  end

      current_external_setting = if cs_elasticsearch_attr.key?('external')
                                   cs_elasticsearch_attr['external']
                                 elsif cs_solr_attr.key?('external')
                                   cs_solr_attr['external']
                                 else
                                   false
                                 end

      if current_external_setting != previous_external_setting
        ChefServer::Warnings.warn err_SOLR009_warn_validation
      end
    end
  end

  def verify_external_url
    if cs_elasticsearch_attr['external'] && !cs_elasticsearch_attr['external_url']
      fail_with err_SOLR010_failed_validation(false)
    end
    if cs_solr_attr['external'] && !cs_solr_attr['external_url']
      fail_with err_SOLR010_failed_validation(true)
    end
  end

  def verify_erchef_config
    provider = @cs_erchef_attr['search_provider']
    return true if provider.nil? # default provider

    case provider
    when 'elasticsearch'
      unless %w(batch inline).include?(@cs_erchef_attr['search_queue_mode'])
        fail_with err_SOLR011_failed_validation
      end
    when 'solr'
    else
      fail_with err_SOLR012_failed_validation
    end
  end

  def err_SOLR002_failed_validation
    <<~EOM

      SOLR002: The #{CHEF_SERVER_NAME} is configured to enable both
               Elasticsearch and Solr. This is an unsupported configuration.

               Please update #{CHEF_SERVER_CONFIG_FILE} such that only one
               search provider is enabled.
      EOM
  end

  def err_SOLR003_failed_validation
    <<~EOM

      SOLR003: The #{CHEF_SERVER_NAME} is configured to use an external search
               index but the internal Elasticsearch is still enabled. This is
               an unsupported configuration.

               To disable the internal Elasticsearch, add the following to #{CHEF_SERVER_CONFIG_FILE}:

                   elasticsearch['enable'] = false

               To use the internal Elasticsearch, consider removing the configuration
               entry for opscode_solr4['external'].

     EOM
  end

  def err_SOLR004_failed_validation
    <<~EOM

      SOLR004: The #{CHEF_SERVER_NAME} is configured to use an external search
               provider but the internal Solr is still enabled. This is an
               unsupported configuration.

               To disable the internal Solr, add the following to #{CHEF_SERVER_CONFIG_FILE}:

                   opscode_solr4['enable'] = false

               Alternatively, if you are attempting to use the internal Solr,
               add the following to #{CHEF_SERVER_CONFIG_FILE}:

                   opscode_solr4['enable'] = true
                   opscode_solr4['external'] = false

    EOM
  end

  def err_SOLR005_failed_validation
    <<~EOM

      SOLR005: The #{CHEF_SERVER_NAME} is configured to use its internal
               Elasticsearch installation, but opscode_solr4 has been manually
               enabled. This is an unsupported configuration.

               Please update #{CHEF_SERVER_CONFIG_FILE} to ensure that
               opscode_solr4 is disabled:

                   opscode_solr4['enable'] = false

    EOM
  end

  def err_SOLR006_failed_validation
    <<~EOM

      SOLR006: The #{CHEF_SERVER_NAME} is configured to use its internal
               Elasticsearch installation, but RabbitMQ has been manually
               enabled. This is an unsupported configuration.

               Please update #{CHEF_SERVER_CONFIG_FILE} to ensure that
               rabbitmq is disabled:

                   rabbitmq['enable'] = false

    EOM
  end

  def err_SOLR007_failed_validation
    <<~EOM

      SOLR007: The #{CHEF_SERVER_NAME} is configured to use its internal
               Elasticsearch installation, but opscode-expander has been
               manually enabled. This is an unsupported configuration.

               Please update #{CHEF_SERVER_CONFIG_FILE} to ensure that
               opscode-expander is disabled:

                   opscode_expander['enable'] = false

    EOM
  end

  def err_SOLR009_warn_validation
    <<~EOM

       SOLR009: The value of opscode_solr4['external'] or elasticsearch['external'] has been changed. Search
                results against the new external search index may be incorrect. Please
                run `chef-server-ctl reindex --all` to ensure correct results

    EOM
  end

  def err_SOLR010_failed_validation(was_solr)
    if was_solr
      <<~EOM

        SOLR010: No external url specified for Elasticsearch depsite opscode_solr4['external']
                 being set to true.

                To use an external Elasticsearch instance, please set:

                     elasticsearch['external'] = true
                     elasticsearch['external_url'] = YOUR_ELASTICSEARCH_URL

                in #{CHEF_SERVER_CONFIG_FILE}
      EOM
    else
      <<~EOM

        SOLR010: No external url specified for Elasticsearch depsite elasticsearch['external']
                 being set to true.

                To use an external Elasticsearch instance, please set:

                     elasticsearch['external'] = true
                     elasticsearch['external_url'] = YOUR_ELASTICSEARCH_URL

                in #{CHEF_SERVER_CONFIG_FILE}
      EOM
    end
  end

  def err_SOLR011_failed_validation
    <<~EOM

      SOLR011: The elasticsearch provider is only supported by the batch or inline
               queue modes. To use the elasticsearch provider, please also set:

               opscode_erchef['search_queue_mode'] = 'batch'

               in #{CHEF_SERVER_CONFIG_FILE}

    EOM
  end

  def err_SOLR012_failed_validation
    <<~EOM
      SOLR012: The specified search provider (#{provider}) is not currently supported.
               Please choose from one of the following search providers:

               solr
               elasticsearch
    EOM
  end
end
