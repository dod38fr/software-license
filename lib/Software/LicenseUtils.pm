use strict;
use warnings;
use Carp;

package Software::LicenseUtils;
# ABSTRACT: little useful bits of code for licensey things

use File::Spec;
use IO::Dir;
use Module::Load;

=method guess_license_from_pod

  my @guesses = Software::LicenseUtils->guess_license_from_pod($pm_text);

Given text containing POD, like a .pm file, this method will attempt to guess
at the license under which the code is available.  This method will either
a list of Software::License classes (or instances) or false.

Calling this method in scalar context is a fatal error.

=cut

my $_v = qr/(?:v(?:er(?:sion|\.))(?: |\.)?)/i;
my @phrases = (
  "under the same (?:terms|license) as perl $_v?6" => [],
  'under the same (?:terms|license) as (?:the )?perl'    => 'Perl_5',
  'affero g'                                    => 'AGPL_3',
  "GNU (?:general )?public license,? $_v?([123])" => sub { "GPL_$_[0]" },
  'GNU (?:general )?public license'             => [ map {"GPL_$_"} (1..3) ],
  "GNU (?:lesser|library) (?:general )?public license,? $_v?([23])\\D"  => sub {
    $_[0] == 2 ? 'LGPL_2_1' : $_[0] == 3 ? 'LGPL_3_0' : ()
  },
  'GNU (?:lesser|library) (?:general )?public license'  => [ qw(LGPL_2_1 LGPL_3_0) ],
  'BSD license'                => 'BSD',
  "Artistic license $_v?(\\d)" => sub { "Artistic_$_[0]_0" },
  'Artistic license'           => [ map { "Artistic_$_\_0" } (1..2) ],
  "LGPL,? $_v?(\\d)"             => sub {
    $_[0] == 2 ? 'LGPL_2_1' : $_[0] == 3 ? 'LGPL_3_0' : ()
  },
  'LGPL'                       => [ qw(LGPL_2_1 LGPL_3_0) ],
  "GPL,? $_v?(\\d)"              => sub { "GPL_$_[0]" },
  'GPL'                        => [ map { "GPL_$_" } (1..3) ],
  'BSD'                        => 'BSD',
  'Artistic'                   => [ map { "Artistic_$_\_0" } (1..2) ],
  'MIT'                        => 'MIT',
);

my %meta_keys  = ();
my %meta1_keys = ();
my %meta2_keys = ();

# find all known Software::License::* modules and get identification data
#
# XXX: Grepping over @INC is dangerous, as it means that someone can change the
# behavior of your code by installing a new library that you don't load.  rjbs
# is not a fan.  On the other hand, it will solve a real problem.  One better
# solution is to check "core" licenses first, then fall back, and to skip (but
# warn about) bogus libraries.  Another is, at least when testing S-L itself,
# to only scan lib/ blib. -- rjbs, 2013-10-20
for my $lib (map { "$_/Software/License" } @INC) {
  next unless -d $lib;
  for my $file (IO::Dir->new($lib)->read) {
    next unless $file =~ m{\.pm$};

    # if it fails, ignore it
    eval {
      (my $mod = $file) =~ s{\.pm$}{};
      my $class = "Software::License::$mod";
      load $class;
      $meta_keys{  $class->meta_name  }{$mod} = undef;
      $meta1_keys{ $class->meta_name  }{$mod} = undef;
      $meta_keys{  $class->meta2_name }{$mod} = undef;
      $meta2_keys{ $class->meta2_name }{$mod} = undef;
      my $name = $class->name;
      unshift @phrases, qr/\Q$name\E/, [$mod];
    };
  }
}

sub guess_license_from_pod {
  my ($class, $pm_text) = @_;
  die "can't call guess_license_* in scalar context" unless wantarray;
  return unless $pm_text =~ /
    (
      =head \d \s+
      (?:licen[cs]e|licensing|copyright|legal)\b
    )
  /ixmsg;

  my $header = $1;

	if (
		$pm_text =~ m/
      \G
      (
        .*?
      )
      (=head\\d.*|=cut.*|)
      \z
    /ixms
  ) {
		my $license_text = "$header$1";

    for (my $i = 0; $i < @phrases; $i += 2) {
      my ($pattern, $license) = @phrases[ $i .. $i+1 ];
			$pattern =~ s{\s+}{\\s+}g
				unless ref $pattern eq 'Regexp';
			if ( $license_text =~ /$pattern/i ) {
        my $match = $1;
				# if ( $osi and $license_text =~ /All rights reserved/i ) {
				# 	warn "LEGAL WARNING: 'All rights reserved' may invalidate Open Source licenses. Consider removing it.";
				# }
        my @result = (ref $license||'') eq 'CODE'  ? $license->($match)
                   : (ref $license||'') eq 'ARRAY' ? @$license
                   :                                 $license;

        return unless @result;
				return map { "Software::License::$_" } sort @result;
			}
		}
	}

	return;
}

=method guess_license_from_meta

  my @guesses = Software::LicenseUtils->guess_license_from_meta($meta_str);

Given the content of the META.(yml|json) file found in a CPAN distribution, this
method makes a guess as to which licenses may apply to the distribution.  It
will return a list of zero or more Software::License instances or classes.

=cut

sub guess_license_from_meta {
  my ($class, $meta_text) = @_;
  die "can't call guess_license_* in scalar context" unless wantarray;

  my ($license_text) = $meta_text =~ m{\b["']?license["']?\s*:\s*["']?([a-z_0-9]+)["']?}gm;

  return unless $license_text and my $license = $meta_keys{ $license_text };

  return map { "Software::License::$_" } sort keys %$license;
}

{
  no warnings 'once';
  *guess_license_from_meta_yml = \&guess_license_from_meta;
}

=method guess_license_from_meta_key

  my @guesses = Software::LicenseUtils->guess_license_from_meta_key($key, $v);

This method returns zero or more Software::License classes known to use C<$key>
as their META key.  If C<$v> is supplied, it specifies whether to treat C<$key>
as a v1 or v2 meta entry.  Any value other than 1 or 2 will raise an exception.

=cut

sub guess_license_from_meta_key {
  my ($self, $key, $v) = @_;

  my $src = (! defined $v) ? \%meta_keys
          : $v eq '1'      ? \%meta1_keys
          : $v eq '2'      ? \%meta2_keys
          : Carp::croak("illegal META version: $v");

  return unless $src->{$key};
  return map { "Software::License::$_" } sort keys %{ $src->{$key} };
}

my %short_name = (
  'GPL-1'      =>  'Software::License::GPL_1',
  'GPL-2'      =>  'Software::License::GPL_2',
  'GPL-3'      =>  'Software::License::GPL_3',
  'LGPL-2'     =>  'Software::License::LGPL_2',
  'LGPL-2.1'   =>  'Software::License::LGPL_2_1',
  'LGPL-3'     =>  'Software::License::LGPL_3_0',
  'LGPL-3.0'   =>  'Software::License::LGPL_3_0',
  'Artistic'   =>  'Software::License::Artistic_1_0',
  'Artistic-1' =>  'Software::License::Artistic_1_0',
  'Artistic-2' =>  'Software::License::Artistic_2_0',
);

=method new_from_short_name

  my $license_object = Software::LicenseUtils->new_from_short_name( {
     short_name => 'GPL-1',
     holder => 'X. Ample'
  }) ;

Create a new L<Software::License> object from the license specified
with C<short_name>. Known short license names are C<GPL-*>, C<LGPL-*> ,
C<Artistic> and C<Artistic-*>. If the short name is not known, this
method will try to create a license object with C<Software::License::> and
the specified short name (e.g. C<Software::License::MIT> with
C<< short_name => 'MIT' >> or C<Software::License::Apache_2_0> with
C<< short_name => 'Apapche-2.0' >>).

=cut

sub new_from_short_name {
  my ( $class, $arg ) = @_;

  Carp::croak "no license short name specified"
    unless defined $arg->{short_name};
  my $subclass = my $short = delete $arg->{short_name};
  $subclass =~ s/[\-.]/_/g;

  my $lic_file = my $lic_class
      = $short_name{$short} || "Software::License::$subclass";

  $lic_file =~ s!::!/!g;
  eval { require "$lic_file.pm"; } ;
  Carp::croak "Unknow license with short name $short ($@)" if $@;

  return $lic_class->new( $arg );
}

1;
