#
# Copyright:: 2020 Chef Software, Inc.
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
require_relative './elasticsearch.rb'

class IndexingPreflightValidator < PreflightValidator
  # The cs_*attr variables hold the user-defined configuration
  attr_reader :cs_es_attr, :cs_solr_attr, :cs_erchef_attr,

  # The node_*attr variables hold the default configuration
  attr_reader :node_es_attr, :node_solr_attr, :node_erchef_attr,

  def initialize(node)
    super
    @cs_es_attr = PrivateChef['elasticsearch']
    @cs_solr_attr = PrivateChef['opscode_solr4']
    @cs_erchef_attr = PrivateChef['opscode_erchef']

    @node_es_attr = node['private_chef']['elasticsearch']
    @node_elasticsearch_attr = node['private_chef']['elasticsearch']
    @node_erchef_attr = node['private_chef']['opscode-erchef']
  end

  def run!
    verify_system_memory
    verify_heap_size
    verify_consistent_reindex_sleep_times
    verify_no_deprecated_indexing_options
  end

  def verify_consistent_reindex_sleep_times
    final_min = cs_erchef_attr['reindex_sleep_min_ms'] || node_erchef_attr['reindex_sleep_min_ms']
    final_max = cs_erchef_attr['reindex_sleep_max_ms'] || node_erchef_attr['reindex_sleep_max_ms']
    if final_min > final_max
      fail_with err_INDEX001_failed_validation(final_min, final_max)
    end
  end

  def verify_no_deprecated_indexing_options
    fail_with err_INDEX002_failed_validation if PrivateChef['deprecated_solr_indexing']
  end

  # checks that system has atleast 4GB memory
  def verify_system_memory
    system_memory_gb = Elasticsearch.node_memory_in_units(node, :total, :gb)
    required_memory_gb = 4 # GB
    if system_memory_gb < required_memory_gb
      fail_with err_INDEX003_insufficient_system_memory(system_memory_gb, required_memory_gb)
    end
  end

  # checks that system specifys a heap size between 1GB and 26GB
  def verify_heap_size
    es_heap_size = @cs_es_attr['heap_size'] || @node_es_attr['heap_size']
    solr_heap_size = @cs_solr4_attr['heap_size'] || 0

    using_sorl = false
    heap_size = if solr_heap_size > es_heap_size
                  using_solr = true
                  solr_heap_size
                else
                  es_heap_size
                end

    min_heap = 1024
    # https://www.elastic.co/guide/en/elasticsearch/reference/current/heap-size.html
    max_heap = 26 * 1024

    if heap_size < min_heap || heap_size > max_heap
      fail_with err_INDEX004_invalid_elasticsearch_heap_size(using_solr)
    end
  end

  def err_INDEX001_failed_validation(final_min, final_max)
    <<~EOM

      INDEX001: opscode_erchef['reindex_sleep_min_ms'] (#{final_min}) is greater than
                opscode_erchef['reindex_sleep_max_ms'] (#{final_max})

                The maximum sleep time should be greater or equal to the minimum sleep
                time.
    EOM
  end

  def err_INDEX002_failed_validation
    <<~EOM
      INDEX002: Deprecated Solr Indexing

                You have configured

                    deprecated_solr_indexing true

                The Solr 4-based indexing pipeline is no longer supported.

                Please contact Chef Support for help moving to the
                Elasticsearch indexing pipeline.
    EOM
  end

  def err_INDEX003_insufficient_system_memory(system_memory, required_memory)
    <<~EOM

      INDEX003: Insufficient system memory

                System has #{system_memory} GB of memory,
                but #{required_memory} GB is required.

    EOM
  end

  def err_INDEX004_invalid_elasticsearch_heap_size(using_solr)
    if using_solr
      <<~EOM
        INDEX004: Invalid elasticsearch heap size

                      opscode_solr4['heap_size'] is #{heap_size}MB

                  This value from the Solr search index configuration cannot
                  be safely used for the new Elasticsearch search index.

                  The recommended heap_size is between 1GB and 26GB. Refer to
                  https://www.elastic.co/guide/en/elasticsearch/reference/6.8/heap-size.html
                  for more information.

                  Consider removing this configuration and adding a new value
                  for
                        elasticsearch['heap_size']

                  within the allowed range to #{CHEF_SERVER_CONFIG_FILE}.

      EOM
    else
      <<~EOM
        INDEX004: Invalid elasticsearch heap size

                      elasticsearch['heap_size'] is #{heap_size}MB

                  The recommended heap_size is between 1GB and 26GB. Refer to
                  https://www.elastic.co/guide/en/elasticsearch/reference/6.8/heap-size.html
                  for more information.
      EOM
    end
  end
end
