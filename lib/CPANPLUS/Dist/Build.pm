package CPANPLUS::Dist::Build;

use strict;
use vars    qw[@ISA $STATUS $VERSION];
@ISA =      qw[CPANPLUS::Dist];

use CPANPLUS::inc;
use CPANPLUS::Internals::Constants;

### these constants were exported by CPANPLUS::Internals::Constants
### in previous versions.. they do the same though. If we want to have
### a normal 'use' here, up the dependency to CPANPLUS 0.056 or higher
BEGIN { 
    require CPANPLUS::Dist::Build::Constants;
    CPANPLUS::Dist::Build::Constants->import()
        if not __PACKAGE__->can('BUILD') && __PACKAGE__->can('BUILD_DIR');
}

use CPANPLUS::Error;

use Config;
use FileHandle;
use Cwd;

use IPC::Cmd                    qw[run];
use Params::Check               qw[check];
use Module::Load::Conditional   qw[can_load check_install];
use Locale::Maketext::Simple    Class => 'CPANPLUS', Style => 'gettext';

local $Params::Check::VERBOSE = 1;

$VERSION = '0.02';

=pod

=head1 NAME

CPANPLUS::Dist::Build

=head1 SYNOPSIS

    my $build = CPANPLUS::Dist->new(
                                format  => 'CPANPLUS::Dist::Build',
                                module  => $modobj,
                            );
                            
    $build->prepare;    # runs Module::Build->new_from_context;                            
    $build->create;     # runs build && build test
    $build->install;    # runs build install


=head1 DESCRIPTION

C<CPANPLUS::Dist::Build> is a distribution class for C<Module::Build>
related modules.
Using this package, you can create, install and uninstall perl
modules. It inherits from C<CPANPLUS::Dist>.

Normal users won't have to worry about the interface to this module,
as it functions transparently as a plug-in to C<CPANPLUS> and will 
just C<Do The Right Thing> when it's loaded.

=head1 ACCESSORS

=over 4

=item parent()

Returns the C<CPANPLUS::Module> object that parented this object.

=item status()

Returns the C<Object::Accessor> object that keeps the status for
this module.

=back

=head1 STATUS ACCESSORS

All accessors can be accessed as follows:
    $build->status->ACCESSOR

=over 4

=item build_pl ()

Location of the Build file.
Set to 0 explicitly if something went wrong.

=item build ()

BOOL indicating if the C<Build> command was successful.

=item test ()

BOOL indicating if the C<Build test> command was successful.

=item prepared ()

BOOL indicating if the C<prepare> call exited succesfully
This gets set after C<perl Build.PL>

=item distdir ()

Full path to the directory in which the C<prepare> call took place,
set after a call to C<prepare>. 

=item created ()

BOOL indicating if the C<create> call exited succesfully. This gets
set after C<Build> and C<Build test>.

=item installed ()

BOOL indicating if the module was installed. This gets set after
C<Build install> exits successfully.

=item uninstalled ()

BOOL indicating if the module was uninstalled properly.

=item _create_args ()

Storage of the arguments passed to C<create> for this object. Used
for recursive calls when satisfying prerequisites.

=item _install_args ()

Storage of the arguments passed to C<install> for this object. Used
for recursive calls when satisfying prerequisites.

=item _mb_object ()

Storage of the C<Module::Build> object we used for this installation.

=back

=cut


=head1 METHODS

=head2 $bool = CPANPLUS::Dist::Build->format_available();

Returns a boolean indicating whether or not you can use this package
to create and install modules in your environment.

=cut

### check if the format is available ###
sub format_available {
    my $mod = "Module::Build";
    unless( can_load( modules => { $mod => '0.2611' } ) ) {
        error( loc( "You do not have '%1' -- '%2' not available",
                    $mod, __PACKAGE__ ) );
        return;
    }

    return 1;
}


=head2 $bool = $dist->init();

Sets up the C<CPANPLUS::Dist::Build> object for use.
Effectively creates all the needed status accessors.

Called automatically whenever you create a new C<CPANPLUS::Dist> object.

=cut

sub init {
    my $dist    = shift;
    my $status  = $dist->status;

    $status->mk_accessors(qw[build_pl build test created installed uninstalled
                             _create_args _install_args _prepare_args
                             _mb_object _buildflags
                            ]);

    ### just in case 'format_available' didn't get called
    require Module::Build;

    return 1;
}

=pod

=head2 $bool = $dist->prepare([perl => '/path/to/perl', buildflags => 'EXTRA=FLAGS', force => BOOL, verbose => BOOL])

C<prepare> prepares a distribution, running C<Module::Build>'s 
C<new_from_context> method, and establishing any prerequisites this
distribution has.

After a succcesfull C<prepare> you may call C<create> to create the
distribution, followed by C<install> to actually install it.

Returns true on success and false on failure.

=cut

sub prepare {
    ### just in case you already did a create call for this module object
    ### just via a different dist object
    my $dist = shift;
    my $self = $dist->parent;

    ### we're also the cpan_dist, since we don't need to have anything
    ### prepared from another installer
    $dist    = $self->status->dist_cpan if      $self->status->dist_cpan;
    $self->status->dist_cpan( $dist )   unless  $self->status->dist_cpan;

    my $cb   = $self->parent;
    my $conf = $cb->configure_object;
    my %hash = @_;

    my $dir;
    unless( $dir = $self->status->extract ) {
        error( loc( "No dir found to operate on!" ) );
        return;
    }

    my $args;
    my( $force, $verbose, $buildflags, $perl);
    {   local $Params::Check::ALLOW_UNKNOWN = 1;
        my $tmpl = {
            force           => {    default => $conf->get_conf('force'),
                                    store   => \$force },
            verbose         => {    default => $conf->get_conf('verbose'),
                                    store   => \$verbose },
            perl            => {    default => $^X, store => \$perl },
            buildflags      => {    default => $conf->get_conf('buildflags'),
                                    store   => \$buildflags },
        };

        $args = check( $tmpl, \%hash ) or return;
    }

    return 1 if $dist->status->prepared && !$force;

    $dist->status->_prepare_args( $args );

    ### chdir to work directory ###
    my $orig = cwd();
    unless( $cb->_chdir( dir => $dir ) ) {
        error( loc( "Could not chdir to build directory '%1'", $dir ) );
        return;
    }

    ### by now we've loaded module::build, and we're using the API, so
    ### it's safe to remove CPANPLUS::inc from our inc path, especially
    ### because it can trip up tests run under taint (just like EU::MM).
    ### turn off our PERL5OPT so no modules from CPANPLUS::inc get
    ### included in make test -- it should build without.
    ### also, modules that run in taint mode break if we leave
    ### our code ref in perl5opt
    ### XXX we've removed the ENV settings from cp::inc, so only need
    ### to reset the @INC
    #local $ENV{PERL5OPT} = CPANPLUS::inc->original_perl5opt;
    #local $ENV{PERL5LIB} = CPANPLUS::inc->original_perl5lib;
    local @INC           = CPANPLUS::inc->original_inc;

    ### but do it *before* the new_from_context, as M::B seems
    ### to be actually running the file...
    ### an unshift in the block seems to be ignored.. somehow...
    #{   my $lib = $self->best_path_to_module_build;
    #    unshift @INC, $lib if $lib;
    #}
    
    ### we're a seperate release now, so 
    #unshift @INC, $self->best_path_to_module_build
    #            if $self->best_path_to_module_build;

    ### this will generate warnings under anything lower than M::B 0.2606
    my %buildflags = $dist->_buildflags_as_hash( $buildflags );
    $dist->status->_buildflags( $buildflags );

    my $fail;
    RUN: {
        ### piece of sh*t, stop DYING! --kane
        my $mb = eval { Module::Build->new_from_context( %buildflags ) };
        #my $mb = eval { Module::Build->new_from_context( ) };
        if( !$mb or $@ ) {
            error(loc("Could not create Module::Build object: %1","$@"));
            $fail++; last RUN;
        }

        $dist->status->_mb_object( $mb );

        ### resolve prereqs ###
        my $prereqs = $dist->_find_prereqs( verbose => $verbose );

        ### XXX mangle prereqs because our uptodate() function can't
        ### handle M::B version ranges -- perhaps always use M::B to
        ### verify if modules are up to date, but that would cause a
        ### dependency
        ### so for now, always use the most recent version of a module
        ### if the prereq was somehow unsatisfied
        my $mangled_prereqs = {};
        for my $mod (keys %$prereqs) {
            my $modobj = $cb->module_tree($mod);
            unless( $modobj ) {
                ### XXX just skip it for now.. not sure if it's the best
                ### thing to do -- but some times a module (like Config)
                ### is not in the index, but it's part of core...
                #error(loc("Unable to find '%1' in the module tree ".
                #          "-- unable to satisfy prerequisites", $mod));
                #$fail++; last RUN;
                next;
            }

            ### ok, so there's several ways this can go.. either you don't
            ### care about the version, then the $mb_version will be 'false'
            ### otherwise you want 'a' version -- means $mb_version may only
            ### contain \d. otherwise we don't know what the hell you
            ### want, and just assume any old version is good enough
            ### XXX of course, this is not necessarily correct *AT ALL*
            my $mb_version = $prereqs->{$mod};
            my $wanted;

            ### anything will do
            unless( $mb_version ) {
                $wanted = 0;

            ### a specific version
            } elsif ( $mb_version =~ /^[\d.]+$/ ) {
                $wanted = $mb_version;

            ### eh, some sort of range...??
            } else {
                $wanted = 0;
            }

            $mangled_prereqs->{ $mod } = $wanted;
        }
        
        $self->status->prereqs( $mangled_prereqs );
    }
    
    ### send out test report? ###
    if( $fail and $conf->get_conf('cpantest') ) {
           $cb->_send_report( 
            module  => $self,
            failed  => $fail,
            buffer  => CPANPLUS::Error->stack_as_string,
            verbose => $verbose,
            force   => $force,
        ) or error(loc("Failed to send test report for '%1'",
                    $self->module ) );
    }

    unless( $cb->_chdir( dir => $orig ) ) {
        error( loc( "Could not chdir back to start dir '%1'", $orig ) );
    }

    ### save where we wrote this stuff -- same as extract dir in normal
    ### installer circumstances
    $dist->status->distdir( $self->status->extract );

    return $dist->status->prepared( $fail ? 0 : 1 );
}

sub _find_prereqs {
    my $dist = shift;
    my $mb   = $dist->status->_mb_object;
    my $self = $dist->parent;

    ### Lame++, at least return an empty hashref...
    my $prereqs = $mb->requires || {};
    $self->status->prereqs( $prereqs );

    return $prereqs;
}

=pod

=head2 $dist->create([perl => '/path/to/perl', buildflags => 'EXTRA=FLAGS', prereq_target => TARGET, force => BOOL, verbose => BOOL, skiptest => BOOL])

C<create> preps a distribution for installation. This means it will
run C<Build> and C<Build test>, via the C<Module::Build> API.
This will also satisfy any prerequisites the module may have.

If you set C<skiptest> to true, it will skip the C<Build test> stage.
If you set C<force> to true, it will go over all the stages of the
C<Build> process again, ignoring any previously cached results. It
will also ignore a bad return value from C<Build test> and still allow
the operation to return true.

Returns true on success and false on failure.

You may then call C<< $dist->install >> on the object to actually
install it.

=cut

sub create {
    ### just in case you already did a create call for this module object
    ### just via a different dist object
    my $dist = shift;
    my $self = $dist->parent;

    ### we're also the cpan_dist, since we don't need to have anything
    ### prepared from another installer
    $dist    = $self->status->dist_cpan if      $self->status->dist_cpan;
    $self->status->dist_cpan( $dist )   unless  $self->status->dist_cpan;

    my $cb   = $self->parent;
    my $conf = $cb->configure_object;
    my $mb   = $dist->status->_mb_object;
    my %hash = @_;

    my $dir;
    unless( $dir = $self->status->extract ) {
        error( loc( "No dir found to operate on!" ) );
        return;
    }

    my $args;
    my( $force, $verbose, $buildflags, $skiptest, $prereq_target,
        $perl, $prereq_format, $prereq_build);
    {   local $Params::Check::ALLOW_UNKNOWN = 1;
        my $tmpl = {
            force           => {    default => $conf->get_conf('force'),
                                    store   => \$force },
            verbose         => {    default => $conf->get_conf('verbose'),
                                    store   => \$verbose },
            perl            => {    default => $^X, store => \$perl },
            buildflags      => {    default => $conf->get_conf('buildflags'),
                                    store   => \$buildflags },
            skiptest        => {    default => $conf->get_conf('skiptest'),
                                    store   => \$skiptest },
            prereq_target   => {    default => '', store => \$prereq_target },
            ### don't set the default format to 'build' -- that is wrong!
            prereq_format   => {    #default => $self->status->installer_type,
                                    default => '',
                                    store   => \$prereq_format },
            prereq_build    => {    default => 0, store => \$prereq_build },                                    
        };

        $args = check( $tmpl, \%hash ) or return;
    }

    return 1 if $dist->status->created && !$force;

    $dist->status->_create_args( $args );

    ### is this dist prepared?
    unless( $dist->status->prepared ) {
        error( loc( "You have not successfully prepared a '%2' distribution ".
                    "yet -- cannot create yet", __PACKAGE__ ) );
        return;
    }

    ### chdir to work directory ###
    my $orig = cwd();
    unless( $cb->_chdir( dir => $dir ) ) {
        error( loc( "Could not chdir to build directory '%1'", $dir ) );
        return;
    }

    ### by now we've loaded module::build, and we're using the API, so
    ### it's safe to remove CPANPLUS::inc from our inc path, especially
    ### because it can trip up tests run under taint (just like EU::MM).
    ### turn off our PERL5OPT so no modules from CPANPLUS::inc get
    ### included in make test -- it should build without.
    ### also, modules that run in taint mode break if we leave
    ### our code ref in perl5opt
    ### XXX we've removed the ENV settings from cp::inc, so only need
    ### to reset the @INC
    #local $ENV{PERL5OPT} = CPANPLUS::inc->original_perl5opt;
    #local $ENV{PERL5LIB} = CPANPLUS::inc->original_perl5lib;
    local @INC           = CPANPLUS::inc->original_inc;

    ### but do it *before* the new_from_context, as M::B seems
    ### to be actually running the file...
    ### an unshift in the block seems to be ignored.. somehow...
    #{   my $lib = $self->best_path_to_module_build;
    #    unshift @INC, $lib if $lib;
    #}
    unshift @INC, $self->best_path_to_module_build
                if $self->best_path_to_module_build;

    ### this will generate warnings under anything lower than M::B 0.2606
    my %buildflags = $dist->_buildflags_as_hash( $buildflags );
    $dist->status->_buildflags( $buildflags );

    my $fail; my $prereq_fail;
    RUN: {

        ### this will set the directory back to the start
        ### dir, so we must chdir /again/
        my $ok = $dist->_resolve_prereqs(
                        force           => $force,
                        format          => $prereq_format,
                        verbose         => $verbose,
                        prereqs         => $self->status->prereqs,
                        target          => $prereq_target,
                        prereq_build    => $prereq_build,
                    );

        unless( $cb->_chdir( dir => $dir ) ) {
            error( loc( "Could not chdir to build directory '%1'", $dir ) );
            return;
        }

        unless( $ok ) {
            #### use $dist->flush to reset the cache ###
            error( loc( "Unable to satisfy prerequisites for '%1' " .
                        "-- aborting install", $self->module ) );
            $dist->status->build(0);
            $fail++; $prereq_fail++;
            last RUN;
        }

        eval { $mb->dispatch('build', %buildflags) };
        if( $@ ) {
            error(loc("Could not run '%1': %2", 'Build', "$@"));
            $dist->status->build(0);
            $fail++; last RUN;
        }

        $dist->status->build(1);

        ### add this directory to your lib ###
        $cb->_add_to_includepath(
            directories => [ BLIB_LIBDIR->( $self->status->extract ) ]
        );

        ### this buffer will not include what tests failed due to a 
        ### M::B/Test::Harness bug. Reported as #9793 with patch 
        ### against 0.2607 on 26/1/2005
        unless( $skiptest ) {
            eval { $mb->dispatch('test', %buildflags) };
            if( $@ ) {
                error(loc("Could not run '%1': %2", 'Build test', "$@"));

                unless($force) {
                    $dist->status->test(0);
                    $fail++; last RUN;
                }
            } else {
                $dist->status->test(1);
            }
        } else {
            msg(loc("Tests skipped"), $verbose);
        }            
    }

    unless( $cb->_chdir( dir => $orig ) ) {
        error( loc( "Could not chdir back to start dir '%1'", $orig ) );
    }

    ### send out test report? ###
    if( $conf->get_conf('cpantest') and not $prereq_fail ) {
        $cb->_send_report(
            module          => $self,
            failed          => $fail,
            buffer          => CPANPLUS::Error->stack_as_string,
            verbose         => $verbose,
            force           => $force,
            tests_skipped   => $skiptest,
        ) or error(loc("Failed to send test report for '%1'",
                    $self->module ) );
    }

    return $dist->status->created( $fail ? 0 : 1 );
}

=head2 $dist->install([verbose => BOOL, perl => /path/to/perl])

Actually installs the created dist.

Returns true on success and false on failure.

=cut

sub install {
    ### just in case you already did a create call for this module object
    ### just via a different dist object
    my $dist = shift;
    my $self = $dist->parent;

    ### we're also the cpan_dist, since we don't need to have anything
    ### prepared from another installer
    $dist    = $self->status->dist_cpan if $self->status->dist_cpan;
    my $mb   = $dist->status->_mb_object;

    my $cb   = $self->parent;
    my $conf = $cb->configure_object;
    my %hash = @_;

    
    my $verbose; my $perl; my $force;
    {   local $Params::Check::ALLOW_UNKNOWN = 1;
        my $tmpl = {
            verbose => { default => $conf->get_conf('verbose'),
                         store   => \$verbose },
            force   => { default => $conf->get_conf('force'),
                         store   => \$force },
            perl    => { default => $conf->get_program('perl') || $^X,
                         store   => \$perl },
        };
    
        my $args = check( $tmpl, \%hash ) or return;
        $dist->status->_install_args( $args );
    }

    my $dir;
    unless( $dir = $self->status->extract ) {
        error( loc( "No dir found to operate on!" ) );
        return;
    }

    my $orig = cwd();

    unless( $cb->_chdir( dir => $dir ) ) {
        error( loc( "Could not chdir to build directory '%1'", $dir ) );
        return;
    }

    ### value set and false -- means failure ###
    if( defined $self->status->installed && 
        !$self->status->installed && !$force
    ) {
        error( loc( "Module '%1' has failed to install before this session " .
                    "-- aborting install", $self->module ) );
        return;
    }

    my $fail;
    my $buildflags = $dist->status->_buildflags;
    ### hmm, how is this going to deal with sudo?
    ### for now, check effective uid, if it's not root,
    ### shell out, otherwise use the method
    if( $> ) {

        ### don't worry about loading the right version of M::B anymore
        ### the 'new_from_context' already added the 'right' path to
        ### M::B at the top of the build.pl
        my $cmd     = [$perl, BUILD->($dir), 'install', $buildflags];
        my $sudo    = $conf->get_program('sudo');
        unshift @$cmd, $sudo if $sudo;


        my $buffer;
        unless( scalar run( command => $cmd,
                            buffer  => \$buffer,
                            verbose => $verbose )
        ) {
            error(loc("Could not run '%1': %2", 'Build install', $buffer));
            $fail++;
        }
    } else {
        my %buildflags = $dist->_buildflags_as_hash($buildflags);

        eval { $mb->dispatch('install', %buildflags) };
        if( $@ ) {
            error(loc("Could not run '%1': %2", 'Build install', "$@"));
            $fail++;
        }
    }


    unless( $cb->_chdir( dir => $orig ) ) {
        error( loc( "Could not chdir back to start dir '%1'", $orig ) );
    }

    return $dist->status->installed( $fail ? 0 : 1 );
}

### returns the string 'foo=bar zot=quux' as (foo => bar, zot => quux)
sub _buildflags_as_hash {
    my $self    = shift;
    my $flags   = shift or return;

    my @argv    = Module::Build->split_like_shell($flags);
    my ($argv)  = Module::Build->read_args(@argv);

    return %$argv;
}


sub dist_dir {
    ### just in case you already did a create call for this module object
    ### just via a different dist object
    my $dist = shift;
    my $self = $dist->parent;

    ### we're also the cpan_dist, since we don't need to have anything
    ### prepared from another installer
    $dist    = $self->status->dist_cpan if $self->status->dist_cpan;
    my $mb   = $dist->status->_mb_object;

    my $cb   = $self->parent;
    my $conf = $cb->configure_object;
    my %hash = @_;

    
    my $dir;
    unless( $dir = $self->status->extract ) {
        error( loc( "No dir found to operate on!" ) );
        return;
    }
    
    ### chdir to work directory ###
    my $orig = cwd();
    unless( $cb->_chdir( dir => $dir ) ) {
        error( loc( "Could not chdir to build directory '%1'", $dir ) );
        return;
    }

    my $fail; my $distdir;
    TRY: {    
        $dist->prepare( @_ ) or (++$fail, last TRY);


        eval { $mb->dispatch('distdir') };
        if( $@ ) {
            error(loc("Could not run '%1': %2", 'Build distdir', "$@"));
            ++$fail, last TRY;
        }

        ### /path/to/Foo-Bar-1.2/Foo-Bar-1.2
        $distdir = File::Spec->catdir( $dir, $self->package_name . '-' .
                                                $self->package_version );

        unless( -d $distdir ) {
            error(loc("Do not know where '%1' got created", 'distdir'));
            ++$fail, last TRY;
        }
    }

    unless( $cb->_chdir( dir => $orig ) ) {
        error( loc( "Could not chdir to start directory '%1'", $orig ) );
        return;
    }

    return if $fail;
    return $distdir;
}    

=head1 KNOWN ISSUES

Below are some of the known issues with Module::Build, that we hope 
the authors will resolve at some point, so we can make full use of
Module::Build's power. 
The number listed is the bug number on C<rt.cpan.org>.

=over 4

=item * Uninstall modules installed by Module::Build (#13308)

Module::Build doesn't write a so called C<packlist> file, which holds
a list of all files installed by a distribution. Without this file we
don't know what to remove. Until Module::Build generates this
C<packlist>, we are unable to remove any installations done by it.

=item * Module::Build's version comparison is not supported.

Module::Build has its own way of defining what versions are considered
satisfactory for a prerequisite, and which ones aren't. This syntax is
something specific to Module::Build and we currently have no way to see
if a module on disk, on cpan or something similar is satisfactory
according to Module::Build's version comparison scheme.
As a work around, we now simply assume that the most recent version on
CPAN satisfies a dependency.

=item * Module::Build doesn't support 'PREFIX' (#8759)

Module::Build doens't support the standard C<Makefile.PL> argument 
C<PREFIX> and dies if it is provided. Even though that's not usually a 
problem, sometimes M::B enabled distros ship a C<Makefile.PL> that 
calls the C<Build.PL> under the hood. In these cases, a C<PREFIX> might
be provided and C<Module::Build> will die.

=item * Module::Build masquerades as Makefile.PL but is not compatible (#13145)

Related to the previous entry, C<Module::Build> can create a 
C<Makefile.PL> which under the hood invokes C<Module::Build>. It however
does not support all the options that C<ExtUtils::MakeMaker> does, and
will die if you try to invoke the file with one of those options.

=item * Module::Build can not be upgraded using it's own API (#13169)

This is due to the fact that the Build file insists on adding a path
to C<@INC> which force the loading of the C<not yet installed>
Module::Build when it shells out to run it's own build procedure:

=item * Module::Build does not provide access to install history (#9793)

C<Module::Build> runs the create, test and install procedures in it's
own processes, but does not provide access to any diagnostic messages of
those processes. As an end result, we can not offer these diagnostic 
messages when, for example, reporting automated build failures to sites
like C<testers.cpan.org>.

=back

=head1 AUTHOR

This module by
Jos Boumans E<lt>kane@cpan.orgE<gt>.

=head1 COPYRIGHT

The CPAN++ interface (of which this module is a part of) is
copyright (c) 2001, 2002, 2003, 2004, 2005 Jos Boumans E<lt>kane@cpan.orgE<gt>.
All rights reserved.

This library is free software;
you may redistribute and/or modify it under the same
terms as Perl itself.

=cut

1;

# Local variables:
# c-indentation-style: bsd
# c-basic-offset: 4
# indent-tabs-mode: nil
# End:
# vim: expandtab shiftwidth=4:
