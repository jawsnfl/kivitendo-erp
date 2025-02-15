package SL::Helper::CreatePDF;

use strict;

use Carp;
use Cwd;
use English qw(-no_match_vars);
use File::Slurp ();
use File::Temp ();
use List::MoreUtils qw(uniq);
use List::Util qw(first);
use String::ShellQuote ();

use SL::Form;
use SL::Common;
use SL::DB::Language;
use SL::DB::Printer;
use SL::MoreCommon;
use SL::Template;
use SL::Template::LaTeX;

use Exporter 'import';
our @EXPORT_OK = qw(create_pdf merge_pdfs find_template);
our %EXPORT_TAGS = (
  all => \@EXPORT_OK,
);

sub create_pdf {
  my ($class, %params) = @_;

  my $userspath       = $::lx_office_conf{paths}->{userspath};
  my $form            = Form->new('');
  $form->{format}     = 'pdf';
  $form->{cwd}        = getcwd();
  $form->{templates}  = $::instance_conf->get_templates;
  $form->{IN}         = $params{template};
  $form->{tmpdir}     = $form->{cwd} . '/' . $userspath;
  my ($suffix)        = $params{template} =~ m{\.(.+)};

  my $vars            = $params{variables} || {};
  $form->{$_}         = $vars->{$_} for keys %{ $vars };

  my $temp_fh;
  ($temp_fh, $form->{tmpfile}) = File::Temp::tempfile(
    'kivitendo-printXXXXXX',
    SUFFIX => ".${suffix}",
    DIR    => $userspath,
    UNLINK => ($::lx_office_conf{debug} && $::lx_office_conf{debug}->{keep_temp_files})? 0 : 1,
  );

  my $parser = SL::Template::LaTeX->new(
    $form->{IN},
    $form,
    \%::myconfig,
    $userspath,
  );

  my $result = $parser->parse($temp_fh);

  close $temp_fh;
  chdir $form->{cwd};

  if (!$result) {
    $form->cleanup;
    die $parser->get_error;
  }

  if (($params{return} || 'content') eq 'file_name') {
    my $new_name = $userspath . '/keep-' . $form->{tmpfile};
    rename $userspath . '/' . $form->{tmpfile}, $new_name;

    $form->cleanup;

    return $new_name;
  }

  my $pdf = File::Slurp::read_file($userspath . '/' . $form->{tmpfile});

  $form->cleanup;

  return $pdf;
}

sub merge_pdfs {
  my ($class, %params) = @_;

  return scalar(File::Slurp::read_file($params{file_names}->[0])) if scalar(@{ $params{file_names} }) < 2;

  my ($temp_fh, $temp_name) = File::Temp::tempfile(
    'kivitendo-printXXXXXX',
    SUFFIX => '.pdf',
    DIR    => $::lx_office_conf{paths}->{userspath},
    UNLINK => ($::lx_office_conf{debug} && $::lx_office_conf{debug}->{keep_temp_files})? 0 : 1,
  );
  close $temp_fh;

  my $input_names = join ' ', String::ShellQuote::shell_quote(@{ $params{file_names} });
  my $exe         = $::lx_office_conf{applications}->{ghostscript} || 'gs';
  my $output      = `$exe -dBATCH -dNOPAUSE -q -sDEVICE=pdfwrite -sOutputFile=${temp_name} ${input_names} 2>&1`;

  die "Executing gs failed: $ERRNO" if !defined $output;
  die $output                       if $? != 0;

  return scalar File::Slurp::read_file($temp_name);
}

sub find_template {
  my ($class, %params) = @_;

  $params{name} or croak "Missing parameter 'name'";

  my $path                 = $::instance_conf->get_templates;
  my $extension            = $params{extension} || "tex";
  my ($printer, $language) = ('', '');

  if ($params{printer} || $params{printer_id}) {
    if ($params{printer} && !ref $params{printer}) {
      $printer = '_' . $params{printer};
    } else {
      $printer = $params{printer} || SL::DB::Printer->new(id => $params{printer_id})->load;
      $printer = $printer->template_code ? '_' . $printer->template_code : '';
    }
  }

  if ($params{language} || $params{language_id}) {
    if ($params{language} && !ref $params{language}) {
      $language = '_' . $params{language};
    } else {
      $language = $params{language} || SL::DB::Language->new(id => $params{language_id})->load;
      $language = $language->template_code ? '_' . $language->template_code : '';
    }
  }

  my @template_files = (
    $params{name} . "${language}${printer}",
    $params{name} . "${language}",
    $params{name},
    "default",
  );

  if ($params{email}) {
    unshift @template_files, (
      $params{name} . "_email${language}${printer}",
      $params{name} . "_email${language}",
    );
  }

  @template_files = map { "${_}.${extension}" } uniq grep { $_ } @template_files;

  my $template = first { -f ($path . "/$_") } @template_files;

  return wantarray ? ($template, @template_files) : $template;
}

1;
__END__

=pod

=encoding utf8

=head1 NAME

SL::Helper::CreatePDF - A helper for creating PDFs from template files

=head1 SYNOPSIS

  # Retrieve a sales order from the database and create a PDF for
  # it:
  my $order               = SL::DB::Order->new(id => …)->load;
  my $print_form          = Form->new('');
  $print_form->{type}     = 'invoice';
  $print_form->{formname} = 'invoice',
  $print_form->{format}   = 'pdf',
  $print_form->{media}    = 'file';

  $order->flatten_to_form($print_form, format_amounts => 1);
  $print_form->prepare_for_printing;

  my $pdf = SL::Helper::CreatePDF->create_pdf(
    template  => 'sales_order',
    variables => $print_form,
  );

=head1 FUNCTIONS

=over 4

=item C<create_pdf %params>

Parses a LaTeX template file, creates a PDF for it and returns either
its content or its file name. The recognized parameters are:

=over 2

=item * C<template> – mandatory. The template file name relative to
the users' templates directory. Must be an existing file name,
e.g. one retrieved by L</find_template>.

=item * C<variables> – optional hash reference containing variables
available to the template.

=item * C<return> – optional scalar containing either C<content> (the
default) or C<file_name>. If it is set to C<file_name> then the file
name of the temporary file containing the PDF is returned, and the
caller is responsible for deleting it. Otherwise a scalar containing
the PDF itself is returned and all temporary files have already been
deleted by L</create_pdf>.

=back

=item C<find_template %params>

Searches the user's templates directory for a template file name to
use. The file names considered depend on the parameters; they can
contain a template base name and suffixes for email, language and
printers. As a fallback the name C<default.$extension> is also
considered.

The return value depends on the context. In scalar context the
template file name that matches the given parameters is returned. It's
a file name relative to the user's templates directory. If no template
file is found then C<undef> is returned.

In list context the first element is the same value as in scalar
context. Additionally a list of considered template file names is
returned.

The recognized parameters are:

=over 2

=item * C<name> – mandatory. The template's file name basis
without any additional suffix or extension, e.g. C<sales_quotation>.

=item * C<extension> – optional file name extension to use without the
dot. Defaults to C<tex>.

=item * C<email> – optional flag indicating whether or not the
template is to be sent via email. If set to true then template file
names containing C<_email> are considered as well.

=item * C<language> and C<language_id> – optional parameters
indicating the language to be used. C<language> can be either a string
containing the language code to use or an instance of
C<SL::DB::Language>. C<language_id> can contain the ID of the
C<SL::DB:Language> instance to load and use. If given template file
names containing C<_language_template_code> are considered as well.

=item * C<printer> and C<printer_id> – optional parameters indicating
the printer to be used. C<printer> can be either a string containing
the printer code to use or an instance of
C<SL::DB::Printer>. C<printer_id> can contain the ID of the
C<SL::DB:Printer> instance to load and use. If given template file
names containing C<_printer_template_code> are considered as well.

=back

=item C<merge_pdfs %params>

Merges two or more PDFs into a single PDF by using the external
application ghostscript.

The recognized parameters are:

=over 2

=item * C<file_names> – mandatory array reference containing the file
names to merge.

=back

Note that this function relies on the presence of the external
application ghostscript. The executable to use is configured via
kivitendo's configuration file setting C<application.ghostscript>.

=back

=head1 BUGS

Nothing here yet.

=head1 AUTHOR

Moritz Bunkus E<lt>m.bunkus@linet-services.deE<gt>

=cut
