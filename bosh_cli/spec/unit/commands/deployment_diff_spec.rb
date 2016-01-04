require 'spec_helper'

module Bosh::Cli::Command
  context 'showing manifest and cloud config changes' do
    let(:director) { instance_double(Bosh::Cli::Client::Director) }
    let(:manifest) do
      manifest = Bosh::Cli::Manifest.new(new_manifest, director)
      manifest.load
      manifest
    end
    let(:deployment_diff) { DeploymentDiff.new(director, manifest) }
    let(:options) { {interactive: true, redact_diff: false} }

    def old_manifest
      spec_asset('manifests/old_manifest.yml')
    end

    def new_manifest
      spec_asset('manifests/new_manifest.yml')
    end

    context 'when using an old director that does not have a diffing endpoint' do
      it 'uses the deprecated CLI differ' do
        expect(director).to receive(:diff_deployment).with('test', manifest.yaml).and_raise(Bosh::Cli::ResourceNotFound)
        expect(director).to receive(:get_deployment).with('test').and_return({'manifest' => File.read(old_manifest)})
        output = ''
        allow(Bosh::Cli::Config).to receive_message_chain(:output, :print) do |e|
          output += e
        end

        deployment_diff.print(options)

        expect(output).to eq(<<-DIFF

Detecting deployment changes
----------------------------
Releases
No changes

Compilation
No changes

Update
No changes

Resource pools
No changes

Disk pools
No changes

Networks
No changes

Jobs
new_job
  + name: new_job
  + template: xyz
  + networks: [{"name"=>"default"}]
old_job
  - name: old_job
  - template: xyz
  - networks: [{"name"=>"default"}]

Properties
No changes

                          DIFF
                          )
      end
    end

    context 'when using a new director' do
      let(:diff_json) do
        {
          'cloud_config_id' => 1,
          'diff' => [
            ['resource_pools:', nil],
            ['- name: a', nil],
            ['  cloud_properties:', nil],
            ['    name: new_property', 'added'],
            ['    size: large', 'added'],
            ['jobs:', nil],
            ['- name: new_job', 'added'],
            ['  templates: xyz', 'added'],
            ['  networks:', 'added'],
            ['  - name: a', 'added'],
            ['- name: old_job', 'removed'],
            ['  templates:', 'removed'],
            ['  - name: xyz', 'removed'],
            ['  networks:', 'removed'],
            ['  - name: a', 'removed'],
          ]
        }
      end

      it 'colourizes and displays the diff' do
        Bosh::Cli::Config.colorize = true

        expect(director).to receive(:diff_deployment).with('test', manifest.yaml).and_return(diff_json)
        output = ''
        allow(Bosh::Cli::Config).to receive_message_chain(:output, :print) do |e|
          output += e
        end

        deployment_diff.print(options)

        expect(output.split("\n")).to eq([
          '',
          'Detecting deployment changes',
          '----------------------------',
          'resource_pools:',
          '- name: a',
          '  cloud_properties:',
          '    name: new_property'.make_green,
          '    size: large'.make_green,
          'jobs:',
          '- name: new_job'.make_green,
          '  templates: xyz'.make_green,
          '  networks:'.make_green,
          '  - name: a'.make_green,
          '- name: old_job'.make_red,
          '  templates:'.make_red,
          '  - name: xyz'.make_red,
          '  networks:'.make_red,
          '  - name: a'.make_red
        ])
      end
    end
  end
end
