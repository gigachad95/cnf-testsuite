# coding: utf-8
require "sam"
require "file_utils"
require "colorize"
require "totem"
require "kernel_introspection"
require "k8s_kernel_introspection"
require "../utils/utils.cr"

desc "In order to maintain, debug, and have insight into a protected environment, its infrastructure elements must have the property of being observable. This means these elements must externalize their internal states in some way that lends itself to metrics, tracing, and logging."
task "observability", ["log_output", "prometheus_traffic", "open_metrics", "routed_logs", "tracing"] do |_, args|
  stdout_score("observability", "Observability and Diagnostics")
  case "#{ARGV.join(" ")}" 
  when /observability/
    stdout_info "Results have been saved to #{CNFManager::Points::Results.file}".colorize(:green)
  end
end

desc "Check if the CNF outputs logs to stdout or stderr"
task "log_output" do |_, args|
  CNFManager::Task.task_runner(args) do |args,config|
    task_start_time = Time.utc
    testsuite_task = "log_output"
    Log.for(testsuite_task).info { "Starting test" }

    task_response = CNFManager.workload_resource_test(args, config) do |resource, container, initialized|
      test_passed = false
      case resource["kind"].downcase
      when "replicaset", "deployment", "statefulset", "pod", "daemonset"
        result = KubectlClient.logs("#{resource["kind"]}/#{resource["name"]}", namespace: resource[:namespace], options: "--all-containers --tail=5 --prefix=true")
        Log.for("Log lines").info { result[:output] }
        if result[:output].size > 0
          test_passed = true
        end
      end
      test_passed
    end

    emoji_observability="📶☠️"
    emoji_observability="📶☠️"

    if task_response
      upsert_passed_task(testsuite_task, "✔️  🏆 PASSED: Resources output logs to stdout and stderr #{emoji_observability}", task_start_time)
    else
      upsert_failed_task(testsuite_task, "✖️  🏆 FAILED: Resources do not output logs to stdout and stderr #{emoji_observability}", task_start_time)
    end
  end
end

desc "Does the CNF emit prometheus traffic"
task "prometheus_traffic" do |_, args|
  Log.info { "Running: prometheus_traffic" }
  next if args.named["offline"]?
  task_response = CNFManager::Task.task_runner(args) do |args, config|
    task_start_time = Time.utc
    testsuite_task = "prometheus_traffic"
    Log.for(testsuite_task).info { "Starting test" }

    release_name = config.cnf_config[:release_name]
    destination_cnf_dir = config.cnf_config[:destination_cnf_dir] 

    do_this_on_each_retry = ->(ex : Exception, attempt : Int32, elapsed_time : Time::Span, next_interval : Time::Span) do
      Log.info { "#{ex.class}: '#{ex.message}' - #{attempt} attempt in #{elapsed_time} seconds and #{next_interval} seconds until the next try."}
    end

    emoji_observability="📶☠️"

    matching_processes = KernelIntrospection::K8s.find_matching_processes(CloudNativeIntrospection::PROMETHEUS_PROCESS)
    Log.for("prometheus_traffic:process_search").info { "Found #{matching_processes.size} matching processes for prometheus" }

    prom_json : JSON::Any | Nil = nil
    matching_processes.map do |process_info|
      Log.for("prometheus_traffic:service_for_pod").info { "Checking process: #{process_info[:pid]}"}
      service = KubectlClient::Get.service_by_pod(process_info[:pod])
      next if service.nil?
      service_name = service.dig("metadata", "name")
      service_namespace = "default"
      if service.dig?("metadata", "namespace")
        service_namespace = service.dig("metadata", "namespace")
      end

      Log.for("prometheus_traffic:service_url").info { "Checking ports on service_name: #{service_name}"}
      service_ports = service.dig("spec", "ports")
      port_result = service_ports.as_a.map do |service_port|
        port = service_port.dig("port")
        protocol = service_port.dig("protocol")
        next if protocol != "TCP"
        protocol = port == 443 ? "https" : "http"
        service_url = "#{protocol}://#{service_name}.#{service_namespace}.svc.cluster.local:#{port}"
        begin
          prom_api_resp = ClusterTools.exec("curl #{service_url}/api/v1/targets?state=active")
          Log.debug { "prom_api_resp: #{prom_api_resp}"}
          prom_json = JSON.parse(prom_api_resp[:output])
          Log.for("prometheus_traffic:service_url_pass").info { "Prometheus service_url: #{service_url}" }
          break
        rescue ex
          Log.for("prometheus_traffic:service_url_fail").info { "Failed prometheus service_url: #{service_url}" }
        end
      end
    end

    if !prom_json.nil?
      matched_target = false
      active_targets = prom_json.dig("data", "activeTargets")
      Log.debug { "active_targets: #{active_targets}"}
      prom_target_urls = active_targets.as_a.reduce([] of String) do |acc, target|
        acc << target.dig("scrapeUrl").as_s
        acc << target.dig("globalUrl").as_s
      end
      Log.info { "prom_target_urls: #{prom_target_urls}"}
      prom_cnf_match = CNFManager.workload_resource_test(args, config) do |resource_name, container, initialized|
        ip_match = false
        resource = KubectlClient::Get.resource(resource_name[:kind], resource_name[:name], resource_name[:namespace])
        pods = KubectlClient::Get.pods_by_resource(resource)
        pods.each do |pod|
          pod_ips = pod.dig("status", "podIPs")
          Log.info { "pod_ips: #{pod_ips}"}
          pod_ips.as_a.each do |ip|
            prom_target_urls.each do |url|
              Log.info { "checking: #{url} against #{ip.dig("ip").as_s}"}
              if url.includes?(ip.dig("ip").as_s)
                msg = Prometheus.open_metric_validator(url)
                # Immutable config maps are only supported in Kubernetes 1.19+
                immutable_configmap = true

                if version_less_than(KubectlClient.server_version, "1.19.0")
                  immutable_configmap = false
                end
                if msg[:status].success?
                  metrics_config_map = Prometheus::OpenMetricConfigMapTemplate.new(
                    "cnf-testsuite-#{release_name}-open-metrics",
                    true,
                    "",
                    immutable_configmap
                  ).to_s
                else
                  Log.info { "Openmetrics failure reason: #{msg[:output]}"}
                  metrics_config_map = Prometheus::OpenMetricConfigMapTemplate.new(
                    "cnf-testsuite-#{release_name}-open-metrics",
                    false,
                    msg[:output],
                    immutable_configmap
                  ).to_s
                end

                Log.debug { "metrics_config_map : #{metrics_config_map}" }
                configmap_path = "#{destination_cnf_dir}/config_maps/metrics_configmap.yml"
                File.write(configmap_path, "#{metrics_config_map}")
                KubectlClient::Delete.file(configmap_path)
                KubectlClient::Apply.file(configmap_path)
                ip_match = true
              end
            end
          end
        end
        ip_match 
      end

      # todo 1) check if scrape_url is ip address that directly matches cnf
      # todo 2) check if scrape_url is ip address that maps to service
      #  -- get ip address for the service
      #  -- match ip address to cnf ip addresses
      # todo check if scrape_url is not an ip, assume it is a service, then do task (2)
      if prom_cnf_match
        upsert_passed_task(testsuite_task,"✔️  ✨PASSED: Your cnf is sending prometheus traffic #{emoji_observability}", task_start_time)
      else
        upsert_failed_task(testsuite_task, "✖️  ✨FAILED: Your cnf is not sending prometheus traffic #{emoji_observability}", task_start_time)
      end
    else
      upsert_skipped_task(testsuite_task, "⏭️  ✨SKIPPED: Prometheus server not found #{emoji_observability}", task_start_time)
    end
  end
end

desc "Does the CNF emit prometheus open metric compatible traffic"
task "open_metrics", ["prometheus_traffic"] do |_, args|
  Log.info { "Running: open_metrics" }
  next if args.named["offline"]?
  task_response = CNFManager::Task.task_runner(args) do |args, config|
    task_start_time = Time.utc
    testsuite_task = "open_metrics"
    Log.for(testsuite_task).info { "Starting test" }

    release_name = config.cnf_config[:release_name]
    configmap = KubectlClient::Get.configmap("cnf-testsuite-#{release_name}-open-metrics")
    emoji_observability="📶☠️"
    if configmap != EMPTY_JSON
      open_metrics_validated = configmap["data"].as_h["open_metrics_validated"].as_s

      if open_metrics_validated == "true"
        upsert_passed_task(testsuite_task,"✔️  ✨PASSED: Your cnf's metrics traffic is OpenMetrics compatible #{emoji_observability}", task_start_time)
      else
        open_metrics_response = configmap["data"].as_h["open_metrics_response"].as_s
        puts "OpenMetrics Failed: #{open_metrics_response}".colorize(:red)
        upsert_failed_task(testsuite_task, "✖️  ✨FAILED: Your cnf's metrics traffic is not OpenMetrics compatible #{emoji_observability}", task_start_time)
      end
    else
      upsert_skipped_task(testsuite_task, "⏭️  ✨SKIPPED: Prometheus traffic not configured #{emoji_observability}", task_start_time)
    end
  end
end

desc "Are the CNF's logs captured by a logging system"
task "routed_logs", ["install_cluster_tools"] do |_, args|
  Log.info { "Running: routed_logs" }
  next if args.named["offline"]?
    emoji_observability="📶☠️"
  task_response = CNFManager::Task.task_runner(args) do |args, config|
    task_start_time = Time.utc
    testsuite_task = "routed_logs"
    Log.for(testsuite_task).info { "Starting test" }

    fluentd_match = FluentD.match()
    fluentbit_match = FluentBit.match()
    fluentbitBitnami_match = FluentDBitnami.match()

    Log.info { "fluentd match: #{fluentd_match}" }
    Log.info { "fluentbit match: #{fluentbit_match}" }
    Log.info { "fluentbitBitnami_match match: #{fluentbitBitnami_match}" }
    if fluentd_match[:found] || fluentbit_match[:found] || fluentbitBitnami_match[:found]
        all_resourced_logged = CNFManager.workload_resource_test(args, config) do |resource_name, container, initialized|
          resource_logged = true 
          resource = KubectlClient::Get.resource(resource_name[:kind], resource_name[:name], resource_name[:namespace])
          pods = KubectlClient::Get.pods_by_resource(resource, namespace: resource_name[:namespace])
          pods.each do |pod|
            # if any pod/container is not monitored by fluentd or fluentbit, fail
            if resource_logged
              if fluentd_match[:found]
                resource_logged = FluentD.app_tailed_by_fluentd?(pod.dig("metadata", "name"), fluentd_match)
              end
              if fluentbit_match[:found]
                resource_logged = FluentBit.app_tailed?(pod.dig("metadata", "name"), fluentbit_match)
              end
              if fluentbitBitnami_match[:found]
                resource_logged = FluentDBitnami.app_tailed_by_fluentd?(pod.dig("metadata", "name"), fluentbitBitnami_match)
              end
            end
          end
          resource_logged
        end
        Log.info { "all_resourced_logged: #{all_resourced_logged}" }
        if all_resourced_logged 
          upsert_passed_task(testsuite_task,"✔️  ✨PASSED: Your cnf's logs are being captured #{emoji_observability}", task_start_time)
        else
          upsert_failed_task(testsuite_task, "✖️  ✨FAILED: Your cnf's logs are not being captured #{emoji_observability}", task_start_time)
        end
    else
      upsert_skipped_task(testsuite_task, "⏭️  ✨SKIPPED: Fluentd or FluentBit not configured #{emoji_observability}", task_start_time)
    end
  end
end

desc "Does the CNF install use tracing?"
task "tracing" do |_, args|
  testsuite_task = "tracing"
  Log.for(testsuite_task).info { "Running test" }
  Log.for(testsuite_task).info { "tracing args: #{args.inspect}" }

  next if args.named["offline"]?
  emoji_tracing_deploy="⎈🚀"

  if check_cnf_config(args) || CNFManager.destination_cnfs_exist?
    CNFManager::Task.task_runner(args) do |args, config|
      task_start_time = Time.utc
      Log.for(testsuite_task).info { "Starting test for CNF" }

      match = JaegerManager.match()
      Log.info { "jaeger match: #{match}" }
      if match[:found]
        helm_chart = config.cnf_config[:helm_chart]
        helm_directory = config.cnf_config[:helm_directory]
        release_name = config.cnf_config[:release_name]
        yml_file_path = config.cnf_config[:yml_file_path]
        configmap = KubectlClient::Get.configmap("cnf-testsuite-#{release_name}-startup-information")
        #TODO check if json is empty
        tracing_used = configmap["data"].as_h["tracing_used"].as_s

        if tracing_used == "true" 
          upsert_passed_task(testsuite_task, "✔️  ✨PASSED: Tracing used #{emoji_tracing_deploy}", task_start_time)
        else
          upsert_failed_task(testsuite_task, "✖️  ✨FAILED: Tracing not used #{emoji_tracing_deploy}", task_start_time)
        end
      else
        upsert_skipped_task(testsuite_task, "⏭️  ✨SKIPPED: Jaeger not configured #{emoji_tracing_deploy}", task_start_time)
      end
    end
  else
    upsert_failed_task(testsuite_task, "✖️  ✨FAILED: No cnf_testsuite.yml found! Did you run the setup task?", Time.utc)
  end
end

