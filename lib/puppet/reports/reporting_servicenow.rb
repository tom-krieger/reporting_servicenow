require 'puppet'
require 'yaml'
require 'json'
require 'rest-client'
require 'base64'
require 'pp'

Puppet::Reports.register_report(:reporting_servicenow) do
  desc 'Send corrective changes to ServiceNow'
  @configfile = File.join([File.dirname(Puppet.settings[:config]), 'reporting_servicenow.yaml'])
  raise(Puppet::ParseError, "Reporting ServiceNOW config file #{@configfile} not readable") unless File.exist?(@configfile)

  @config = YAML.load_file(@configfile)
  SN_URL = @config['api_url']
  SN_USERNAME = @config['username']
  SN_PASSWORD = @config['password']
  PUPPETCONSOLE = @config['console_url']
  DEBUG = @config['debug']
  CATEGORY = @config['category']
  SUBCATEGORY = @config['subcategory']
  CALLERID = @config['caller_id']
  ASSIGNMENTGROUP = @config['assignment_group']
  AUTORESOLVEINCIDENT = @config['auto_resolve_incidents']
  SN_INCIDENTSTATE = @config['incident_state']
  PE_REPORTING_URL_PART = @config['pe_reporting_url_part']

  # write debug output
  def debug(msg)
    timestamp = Time.now.utc.iso8601
    f = File.open('/var/log/puppetlabs/puppetserver/reporting_servicenow.log', 'a')
    f.write("[#{timestamp}]: DEBUG: #{msg}\n") if DEBUG
    f.close
  end

  # resolve incident as puppet fixed the config drift automatically
  def resolve_incident(incident_sys_id, incident_state, username, password)
    request_close_body_map = {
      state: incident_state,
      close_notes: 'Resolved by API (Closed/Resolved By Caller)',
      comments: 'Incident for corrective change resolved automatically by Puppet',
    }

    debug("payload resolve incident:\n#{request_close_body_map}\n-----\n")
    debug("Payload end\n-----\n")
    begin
      url = "#{SN_URL}/#{incident_sys_id}"
      debug("incident resolve url: #{url}")
      response = RestClient.put(url.to_s,
                                request_close_body_map.to_json, # Encode the entire body as JSON
                                authorization: "Basic #{Base64.strict_encode64("#{username}:#{password}")}",
                                content_type:  'application/json',
                                accept:        'application/json',
                                timeout:       120)
    rescue RestClient::ExceptionWithResponse => e
      e.response
    end

    if response
      debug("Incident Close Response: #{response.pretty_inspect}")
      response.headers.each { |k, v| debug("Header: #{k}=#{v}") }
      response_data = JSON.parse(response)
      debug("Response incident close:\n#{response_data.pretty_inspect}\n-----\n")

    elsif e.response
      debug("ERROR incident close:\n#{e.response}\n-----\n")
    else
      debug('No response incident close!')
    end
  end

  def process
    # We only want to send a report if we have a corrective change
    real_status = (status == 'changed' && corrective_change == true) ? "#{status} (corrective)" : status.to_s
    message = "Puppet run resulted in a status of '#{real_status}' in the '#{environment}' environment"

    if real_status != 'changed (corrective)'
      return
    end

    whoami = `hostname -f`.chomp

    debug("SNOW URL: #{SN_URL}")
    debug("SNOW USER: #{SN_USERNAME}")
    debug("SNOW PASS: #{SN_PASSWORD}")
    debug("Puppet Console: #{PUPPETCONSOLE}")
    debug("Puppet Master: #{whoami}")
    debug("Category: #{CATEGORY}")
    debug("Subcategory: #{SUBCATEGORY}")
    debug("Caller Id: #{CALLERID}")
    debug("Assignment group: #{ASSIGNMENTGROUP}")

    line = 'Change details:\n'
    logs.each do |log|
      line = line.to_s + "#{log.time} #{log.level} #{log.message}\n"
    end

    reporting_url = "#{PUPPETCONSOLE}#{PE_REPORTING_URL_PART}/#{host}/reports"
    debug("reporting url: #{reporting_url}")
    request_body_map = {
      type: 'Standard',
      short_description: "Puppet Corrective Change on #{host}",
      assignment_group: ASSIGNMENTGROUP.to_s,
      category: CATEGORY.to_s,
      subcategory: SUBCATEGORY.to_s,
      caller_id: CALLERID.to_s,
      impact: '3',
      urgency: '3',
      risk: '3',
      description: message.to_s,
      justification: "AUTOMATED change from Puppet Master #{whoami}",
      cmdb_ci: host,
      start_date: configuration_version,
      end_date: configuration_version,
      implementation_plan: 'my implementation plan',
      u_risk_resources: '2',
      u_risk_backout: '3',
      u_risk_complex: '1',
      work_notes: "Node Reports: [code]<a class='web' target='_blank' href='#{reporting_url}'>Reports</a>[/code]\n#{line}",
    }

    debug("payload:\n#{request_body_map}\n-----\n")
    debug("Payload end\n-----\n")
    begin
      response = RestClient.post(SN_URL.to_s,
                                 request_body_map.to_json, # Encode the entire body as JSON
                                 authorization: "Basic #{Base64.strict_encode64("#{SN_USERNAME}:#{SN_PASSWORD}")}",
                                 content_type:  'application/json',
                                 accept:        'application/json',
                                 timeout:       120)
    rescue RestClient::ExceptionWithResponse => e
      e.response
    end

    if response
      debug("Response: #{response.pretty_inspect}")
      response.headers.each { |k, v| debug("Header: #{k}=#{v}") }
      response_data = JSON.parse(response)
      debug("Response:\n#{response_data.pretty_inspect}")
      change_number = response_data['result']['number']
      incident_sys_id = response_data['result']['sys_id']
      created = response_data['result']['sys_created_on']
      debug("ServiceNOW Incident #{change_number} was created on #{created} (#{incident_sys_id})\n")

      if AUTORESOLVEINCIDENT
        # resolve incident automatically
        resolve_incident(incident_sys_id, SN_INCIDENTSTATE.to_s, SN_USERNAME.to_s, SN_PASSWORD.to_s)
      end

    elsif e.response
      debug("ERROR incident create:\n#{e.response}\n-----\n")
    else
      debug('No response for incident create!')
    end
  end
end
