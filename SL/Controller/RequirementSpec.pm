package SL::Controller::RequirementSpec;

use strict;
use utf8;

use parent qw(SL::Controller::Base);

use File::Spec ();

use SL::ClientJS;
use SL::Common ();
use SL::Controller::Helper::GetModels;
use SL::Controller::Helper::ReportGenerator;
use SL::Controller::Helper::RequirementSpec;
use SL::DB::Customer;
use SL::DB::Project;
use SL::DB::ProjectStatus;
use SL::DB::ProjectType;
use SL::DB::RequirementSpecComplexity;
use SL::DB::RequirementSpecRisk;
use SL::DB::RequirementSpecStatus;
use SL::DB::RequirementSpecType;
use SL::DB::RequirementSpec;
use SL::Helper::Flash;
use SL::Locale::String;
use SL::Template::LaTeX;

use Rose::Object::MakeMethods::Generic
(
  scalar                  => [ qw(requirement_spec_item visible_item visible_section) ],
  'scalar --get_set_init' => [ qw(requirement_spec customers types statuses complexities risks projects project_types project_statuses default_project_type default_project_status copy_source js
                                  current_text_block_output_position models) ],
);

__PACKAGE__->run_before('setup');
__PACKAGE__->run_before('set_default_filter_args', only => [ qw(list) ]);

my %sort_columns = (
  customer      => t8('Customer'),
  title         => t8('Title'),
  type          => t8('Requirement Spec Type'),
  status        => t8('Requirement Spec Status'),
  projectnumber => t8('Project Number'),
  version       => t8('Version'),
  mtime         => t8('Last modification'),
);

#
# actions
#


sub action_list {
  my ($self) = @_;

  $self->prepare_report;
  $self->report_generator_list_objects(report => $self->{report}, objects => $self->models->get);
}

sub action_new {
  my ($self) = @_;

  $self->requirement_spec(SL::DB::RequirementSpec->new(is_template => $::form->{is_template}));

  if ($self->copy_source) {
    $self->requirement_spec->$_($self->copy_source->$_) for qw(type_id status_id customer_id title hourly_rate is_template)
  }

  $self->render('requirement_spec/new', title => $self->requirement_spec->is_template ? t8('Create a new requirement spec template') : t8('Create a new requirement spec'));
}

sub action_ajax_show_basic_settings {
  my ($self) = @_;

  $self->render('requirement_spec/_show_basic_settings', { layout => 0 });
}

sub action_ajax_edit {
  my ($self) = @_;

  my $html   = $self->render('requirement_spec/_form', { output => 0 }, submit_as => 'ajax');

  $self->js
    ->hide('#basic_settings')
    ->after('#basic_settings', $html)
    ->render($self);
}

sub action_ajax_edit_project_link {
  my ($self) = @_;

  my $html   = $self->render('requirement_spec/_project_link_form', { output => 0 }, submit_as => 'ajax');

  $self->js
    ->hide('#basic_settings')
    ->after('#basic_settings', $html)
    ->render($self);
}

sub action_ajax_show_time_and_cost_estimate {
  my ($self) = @_;

  $self->render('requirement_spec/_show_time_and_cost_estimate', { layout => 0 });
}

sub action_ajax_edit_time_and_cost_estimate {
  my ($self) = @_;

  my $html   = $self->render('requirement_spec/_edit_time_and_cost_estimate', { output => 0 });
  my $first  = ($self->requirement_spec->sections_sorted || [])->[0];
  $first     = ($first->children_sorted || [])->[0] if $first;

  $self->js
   ->hide('#time_cost_estimate')
   ->after('#time_cost_estimate', $html)
   ->on('#time_cost_estimate INPUT[type=text]', 'keydown', 'kivi.requirement_spec.time_cost_estimate_input_key_down')
   ->action_if($first && $first->id, 'focus', '#time_and_cost_estimate_form_complexity_id_' . $first->id)
   ->render($self);
}

sub action_ajax_save_time_and_cost_estimate {
  my ($self) = @_;

  $self->requirement_spec->db->do_transaction(sub {
    # Make Emacs happy
    1;
    foreach my $attributes (@{ $::form->{requirement_spec_items} || [] }) {
      SL::DB::RequirementSpecItem
        ->new(id => delete $attributes->{id})
        ->load
        ->update_attributes(%{ $attributes });
    }

    1;
  });

  $self->requirement_spec(SL::DB::RequirementSpec->new(id => $self->requirement_spec->id)->load);

  my $html = $self->render('requirement_spec/_show_time_and_cost_estimate', { output => 0 }, initially_hidden => !!$::form->{keep_open});
  $self->js->replaceWith('#time_cost_estimate', $html);

  return $self->js->render($self) if $::form->{keep_open};

  $self->js->remove('#time_cost_estimate_form_container');

  if ($self->visible_section) {
    $html = $self->render('requirement_spec_item/_section', { output => 0 }, requirement_spec_item => $self->visible_section);
    $self->js->html('#column-content', $html);
  }

  $self->js->render($self);
}

sub action_show {
  my ($self) = @_;

  my $title  = $self->requirement_spec->is_template ? t8('Show requirement spec template') : t8('Show requirement spec');
  my $item   = $::form->{requirement_spec_item_id} ? SL::DB::RequirementSpecItem->new(id => $::form->{requirement_spec_item_id})->load : @{ $self->requirement_spec->sections_sorted }[0];
  $self->requirement_spec_item($item);

  $self->render('requirement_spec/show', title => $title);
}

sub action_create {
  my ($self) = @_;

  $self->requirement_spec(SL::DB::RequirementSpec->new);
  $self->create_or_update;
}

sub action_update {
  my ($self) = @_;
  $self->create_or_update;
}

sub action_update_project_link {
  my $self   = shift;
  my $action = delete($::form->{project_link_action}) || 'keep';

  return $self->update_project_link_none_keep_existing($action) if $action =~ m{none|keep|existing};
  return $self->update_project_link_new($action)                if $action eq 'new';
  return $self->update_project_link_create($action)             if $action eq 'create';

  die "Unknown project link action '$action'";
}

sub action_destroy {
  my ($self) = @_;

  if (eval { $self->requirement_spec->delete; 1; }) {
    flash_later('info',  t8('The requirement spec has been deleted.'));
  } else {
    flash_later('error', t8('The requirement spec is in use and cannot be deleted.'));
  }

  $self->redirect_to(action => 'list');
}

sub action_revert_to {
  my ($self, %params) = @_;

  return $self->js->error(t8('Cannot revert a versioned copy.'))->render($self) if $self->requirement_spec->working_copy_id;

  my $versioned_copy = SL::DB::RequirementSpec->new(id => $::form->{versioned_copy_id})->load;

  $self->requirement_spec->copy_from($versioned_copy);
  my $version = $versioned_copy->versions->[0];
  $version->update_attributes(working_copy_id => $self->requirement_spec->id);

  flash_later('info', t8('The requirement spec has been reverted to version #1.', $self->requirement_spec->version->version_number));
  $self->js->redirect_to($self->url_for(action => 'show', id => $self->requirement_spec->id))->render($self);
}

sub action_create_pdf {
  my ($self, %params) = @_;

  my $base_name       = $self->requirement_spec->type->template_file_name || 'requirement_spec';
  my @pictures        = $self->prepare_pictures_for_printing;
  my %result          = SL::Template::LaTeX->parse_and_create_pdf("${base_name}.tex", SELF => $self, rspec => $self->requirement_spec);

  unlink @pictures unless ($::lx_office_conf{debug} || {})->{keep_temp_files};

  $::form->error(t8('Conversion to PDF failed: #1', $result{error})) if $result{error};

  my $attachment_name  =  $self->requirement_spec->type->description . ' ' . ($self->requirement_spec->working_copy_id || $self->requirement_spec->id);
  $attachment_name    .=  ' (v' . $self->requirement_spec->version->version_number . ')' if $self->requirement_spec->version;
  $attachment_name    .=  '.pdf';
  $attachment_name     =~ s/[^\wäöüÄÖÜß \-\+\(\)\[\]\{\}\.,]+/_/g;

  $self->send_file($result{file_name}, type => 'application/pdf', name => $attachment_name);
  unlink $result{file_name};
}

sub action_select_template_to_paste {
  my ($self) = @_;

  my @templates = grep { @{ $_->sections } || @{ $_->text_blocks } } @{ SL::DB::Manager::RequirementSpec->get_all(where => [ is_template => 1 ], sort_by => 'lower(title)') };
  $self->render('requirement_spec/select_template_to_paste', { layout => 0 }, TEMPLATES => \@templates);
}

sub action_paste_template {
  my ($self, %params) = @_;

  my $template = SL::DB::RequirementSpec->new(id => $::form->{template_id})->load;
  my %result   = $self->requirement_spec->paste_template($template);

  return $self->js->error($self->requirement_spec->error)->render($self) if !%result;

  $self->render_pasted_text_block($_) for sort { $a->position <=> $b->position } @{ $result{text_blocks} };
  $self->render_pasted_section($_)    for sort { $a->position <=> $b->position } @{ $result{sections}    };

  if (@{ $result{sections} } && (($::form->{current_content_type} || 'sections') eq 'sections') && !$::form->{current_content_id}) {
    $self->render_first_pasted_section_as_list($result{sections}->[0]);
  }

  $self->invalidate_version->render($self);
}

#
# filters
#

sub setup {
  my ($self) = @_;

  $::auth->assert('requirement_spec_edit');
  $::request->{layout}->use_stylesheet("${_}.css") for qw(jquery.contextMenu requirement_spec);
  $::request->{layout}->use_javascript("${_}.js")  for qw(jquery.jstree jquery/jquery.contextMenu jquery/jquery.hotkeys requirement_spec ckeditor/ckeditor ckeditor/adapters/jquery);
  $self->init_visible_section;

  return 1;
}

sub init_js                     { SL::ClientJS->new                                           }
sub init_complexities           { SL::DB::Manager::RequirementSpecComplexity->get_all_sorted  }
sub init_default_project_status { SL::DB::Manager::ProjectStatus->find_by(name => 'planning') }
sub init_default_project_type   { SL::DB::ProjectType->new(id => 1)->load                     }
sub init_project_statuses       { SL::DB::Manager::ProjectStatus->get_all_sorted              }
sub init_project_types          { SL::DB::Manager::ProjectType->get_all_sorted                }
sub init_projects               { SL::DB::Manager::Project->get_all_sorted                    }
sub init_risks                  { SL::DB::Manager::RequirementSpecRisk->get_all_sorted        }
sub init_statuses               { SL::DB::Manager::RequirementSpecStatus->get_all_sorted      }
sub init_types                  { SL::DB::Manager::RequirementSpecType->get_all_sorted        }

sub init_customers {
  my ($self) = @_;

  my @filter = ('!obsolete' => 1);
  @filter    = ( or => [ @filter, id => $self->requirement_spec->customer_id ] ) if $self->requirement_spec && $self->requirement_spec->customer_id;

  return SL::DB::Manager::Customer->get_all_sorted(where => \@filter);
}

sub init_requirement_spec {
  my ($self) = @_;
  $self->requirement_spec(SL::DB::RequirementSpec->new(id => $::form->{id})->load || die "No such requirement spec") if $::form->{id};
}

sub init_copy_source {
  my ($self) = @_;
  $self->copy_source(SL::DB::RequirementSpec->new(id => $::form->{copy_source_id})->load) if $::form->{copy_source_id};
}

sub init_current_text_block_output_position {
  my ($self) = @_;
  $self->current_text_block_output_position($::form->{current_content_type} !~ m/^(?:text-blocks|tb)-(front|back)/ ? -1 : $1 eq 'front' ? 0 : 1);
}

#
# helpers
#

sub create_or_update {
  my $self   = shift;
  my $is_new = !$self->requirement_spec->id;
  my $params = delete($::form->{requirement_spec}) || { };

  $self->requirement_spec->assign_attributes(%{ $params });

  my $title  = $is_new && $self->requirement_spec->is_template ? t8('Create a new requirement spec template')
             : $is_new                                         ? t8('Create a new requirement spec')
             :            $self->requirement_spec->is_template ? t8('Edit requirement spec template')
             :                                                   t8('Edit requirement spec');

  my @errors = $self->requirement_spec->validate;

  if (@errors) {
    return $self->js->error(@errors)->render($self) if $::request->is_ajax;

    flash('error', @errors);
    $self->render('requirement_spec/new', title => $title);
    return;
  }

  my $db = $self->requirement_spec->db;
  if (!$db->do_transaction(sub {
    if ($self->copy_source) {
      $self->requirement_spec($self->copy_source->create_copy(%{ $params }));
    } else {
      $self->requirement_spec->save;
    }
  })) {
    $::lxdebug->message(LXDebug::WARN(), "Error: " . $db->error);
    @errors = ($::locale->text('Saving failed. Error message from the database: #1', $db->error));
    return $self->js->error(@errors)->render($self) if $::request->is_ajax;

    $self->requirement_spec->id(undef) if $is_new;
    flash('error', @errors);
    return $self->render('requirement_spec/new', title => $title);
  }

  my $info = $self->requirement_spec->is_template ? t8('The requirement spec template has been saved.') : t8('The requirement spec has been saved.');

  if ($::request->is_ajax) {
    my $header_html = $self->render('requirement_spec/_header', { output => 0 });
    my $basics_html = $self->render('requirement_spec/_show_basic_settings', { output => 0 });
    return $self->invalidate_version
      ->replaceWith('#requirement-spec-header', $header_html)
      ->replaceWith('#basic_settings',          $basics_html)
      ->remove('#basic_settings_form')
      ->flash('info', $info)
      ->render($self);
  }

  flash_later('info', $info);
  $self->redirect_to(action => 'show', id => $self->requirement_spec->id);
}

sub prepare_report {
  my ($self)      = @_;

  my $is_template = $::form->{is_template};
  my $report      = SL::ReportGenerator->new(\%::myconfig, $::form);

  $self->models->disable_plugin('paginated') if $report->{options}{output_format} =~ /^(pdf|csv)$/i;
  $self->models->finalize; # for filter laundering
  my $callback    = $self->models->get_callback;

  $self->{report} = $report;

  my @columns     = $is_template ? qw(title mtime) : qw(title customer status type projectnumber mtime version);
  my @sortable    = $is_template ? qw(title mtime) : qw(title customer status type projectnumber mtime);

  my %column_defs = (
    title         => { obj_link => sub { $self->url_for(action => 'show', id => $_[0]->id, callback => $callback) } },
    mtime         => { sub      => sub { ($_[0]->mtime || $_[0]->itime)->to_kivitendo(precision => 'minute') } },
  );

  if (!$is_template) {
    %column_defs = (
      %column_defs,
      customer      => { raw_data => sub { $self->presenter->customer($_[0]->customer, display => 'table-cell', callback => $callback) },
                         sub      => sub { $_[0]->customer->name } },
      projectnumber => { raw_data => sub { $self->presenter->project($_[0]->project, display => 'table-cell', callback => $callback) },
                         sub      => sub { $_[0]->project_id ? $_[0]->project->projectnumber : '' } },
      status        => { sub      => sub { $_[0]->status->description } },
      type          => { sub      => sub { $_[0]->type->description } },
      version       => { sub      => sub { $_[0]->version ? $_[0]->version->version_number : t8('Working copy without version') } },
    );
  }

  map { $column_defs{$_}->{text} ||= $::locale->text( $self->models->get_sort_spec->{$_}->{title} ) } keys %column_defs;

  $report->set_options(
    std_column_visibility => 1,
    controller_class      => 'RequirementSpec',
    output_format         => 'HTML',
    raw_top_info_text     => $self->render('requirement_spec/report_top',    { output => 0 }, is_template => $is_template),
    raw_bottom_info_text  => $self->render('requirement_spec/report_bottom', { output => 0 }, models => $self->models),
    title                 => $is_template ? t8('Requirement Spec Templates') : t8('Requirement Specs'),
    allow_pdf_export      => 1,
    allow_csv_export      => 1,
  );
  $report->set_columns(%column_defs);
  $report->set_column_order(@columns);
  $report->set_export_options(qw(list filter));
  $report->set_options_from_form;
  $self->models->set_report_generator_sort_options(report => $report, sortable_columns => \@sortable);
}

sub invalidate_version {
  my ($self) = @_;

  my $rspec  = SL::DB::RequirementSpec->new(id => $self->requirement_spec->id)->load;
  return $self->js if $rspec->is_template;

  $rspec->invalidate_version;

  my $html = $self->render('requirement_spec/_version', { output => 0 }, requirement_spec => $rspec);
  return $self->js->html('#requirement_spec_version', $html);
}

sub render_pasted_text_block {
  my ($self, $text_block, %params) = @_;

  if ($self->current_text_block_output_position == $text_block->output_position) {
    my $html = $self->render('requirement_spec_text_block/_text_block', { output => 0 }, text_block => $text_block);
    $self->js
      ->appendTo($html, '#text-block-list')
      ->hide('#text-block-list-empty');
  }

  my $node       = $self->presenter->requirement_spec_text_block_jstree_data($text_block);
  my $front_back = $text_block->output_position == 0 ? 'front' : 'back';
  $self->js
    ->jstree->create_node('#tree', "#tb-${front_back}", 'last', $node)
    ->jstree->open_node(  '#tree', "#tb-${front_back}");
}

sub set_default_filter_args {
  my ($self) = @_;

  if (!$::form->{filter} && !$::form->{is_template}) {
    $::form->{filter} = {
      status_id => [ map { $_->{id} } grep { $_->name ne 'done' } @{ $self->statuses } ],
    };
  }

  return 1;
}

sub render_pasted_section {
  my ($self, $item, $parent_id) = @_;

  my $node = $self->presenter->requirement_spec_item_jstree_data($item);
  $self->js
    ->jstree->create_node('#tree', $parent_id ? "#fb-${parent_id}" : '#sections', 'last', $node)
    ->jstree->open_node(  '#tree', $parent_id ? "#fb-${parent_id}" : '#sections');

  $self->render_pasted_section($_, $item->id) for @{ $item->children_sorted };
}

sub render_first_pasted_section_as_list {
  my ($self, $section, %params) = @_;

  my $html = $self->render('requirement_spec_item/_section', { output => 0 }, requirement_spec_item => $section);
  $self->js
    ->html('#column-content', $html)
    ->val( '#current_content_type', $section->item_type)
    ->val( '#current_content_id',   $section->id)
    ->jstree->select_node('#tree', '#fb-' . $section->id);
}

sub prepare_pictures_for_printing {
  my ($self) = @_;

  my @files;
  my $userspath = File::Spec->rel2abs($::lx_office_conf{paths}->{userspath});
  my $target    =  "${userspath}/kivitendo-print-requirement-spec-picture-" . Common::unique_id() . '-';

  foreach my $picture (map { @{ $_->pictures } } @{ $self->requirement_spec->text_blocks }) {
    my $output_file_name        = $target . $picture->id . '.' . $picture->get_default_file_name_extension;
    $picture->{print_file_name} = File::Spec->abs2rel($output_file_name, $userspath);
    my $out                     = IO::File->new($output_file_name, 'w') || die("Could not create file " . $output_file_name);
    $out->binmode;
    $out->print($picture->picture_content);
    $out->close;

    push @files, $output_file_name;
  }

  return @files;
}

sub update_project_link_none_keep_existing {
  my ($self, $action) = @_;

  $self->requirement_spec->update_attributes(project_id => undef)                     if $action eq 'none';
  $self->requirement_spec->update_attributes(project_id => $::form->{new_project_id}) if $action eq 'existing';

  return $self->invalidate_version
    ->replaceWith('#basic_settings', $self->render('requirement_spec/_show_basic_settings', { output => 0 }))
    ->remove('#project_link_form')
    ->flash('info', t8('The project link has been updated.'))
    ->render($self);
}

sub update_project_link_new {
  my ($self) = @_;

  return $self->js
    ->replaceWith('#project_link_form', $self->render('requirement_spec/_new_project_form', { output => 0 }))
    ->render($self);
}

sub update_project_link_create {
  my ($self)  = @_;
  my $params  = delete($::form->{project}) || {};
  my $project = SL::DB::Project->new(
    %{ $params },
    valid  => 1,
    active => 1,
  );

  my @errors = $project->validate;

  return $self->js->error(@errors)->render($self) if @errors;

  my $db = $self->requirement_spec->db;
  if (!$db->do_transaction(sub {
    $project->save;
    $self->requirement_spec->update_attributes(project_id => $project->id);

  })) {
    $::lxdebug->message(LXDebug::WARN(), "Error: " . $db->error);
    return $self->js->error(t8('Saving failed. Error message from the database: #1', $db->error))->render($self);
  }

  return $self->invalidate_version
    ->replaceWith('#basic_settings', $self->render('requirement_spec/_show_basic_settings', { output => 0 }))
    ->remove('#project_link_form')
    ->flash('info', t8('The project has been created.'))
    ->flash('info', t8('The project link has been updated.'))
    ->render($self);
}

sub init_models {
  my ($self) = @_;

  SL::Controller::Helper::GetModels->new(
    controller   => $self,
    sorted       => {
      _default     => {
        by           => 'customer',
        dir          => 1,
      },
      %sort_columns,
    },
    query => [
      and => [
        working_copy_id => undef,
        is_template     => $::form->{is_template} ? 1 : 0,
      ],
    ],
    with_objects => [ 'customer', 'type', 'status', 'project' ],
  );
}

1;
