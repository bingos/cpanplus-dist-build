BEGIN { chdir 't' if -d 't' };

### this is to make devel::cover happy ###
BEGIN {
    use File::Spec;
    require lib;
    for (qw[../lib inc]) {
        my $l = 'lib'; $l->import(File::Spec->rel2abs($_)) 
    }
}

use strict;
use CPANPLUS::Configure;
use CPANPLUS::Backend;
use CPANPLUS::Internals::Constants;
use CPANPLUS::Module::Fake;
use CPANPLUS::Module::Author::Fake;

use Config;
use Test::More      'no_plan';
use File::Basename  ();
use Data::Dumper;
use Config;
use IPC::Cmd        'can_run';

my $Class   = 'CPANPLUS::Dist::Build';
my $Utils   = 'CPANPLUS::Internals::Utils';
my $Have_CC =  can_run($Config{'cc'} )? 1 : 0;


my $Lib     = File::Spec->rel2abs(File::Spec->catdir( qw[dummy-perl] ));
my $Src     = File::Spec->rel2abs(File::Spec->catdir( qw[src] ));


my $Verbose = @ARGV ? 1 : 0;
my $Conf    = CPANPLUS::Configure->new( 
                conf => {   
                    base        => 'dummy-cpanplus',   
                    dist_type   => '',
                    verbose     => $Verbose,
                    ### running tests will mess with the test output 
                    ### counter so skip 'm
                    skiptest    => 1,
                } );

my $CB      = CPANPLUS::Backend->new( $Conf );

                # path, cc needed?
my %Map     = ( noxs    => 0,
                xs      => 1 
            );        


### Disable certain possible settings, so we dont accidentally
### touch anything outside our sandbox
{   
    ### set buildflags to install in our dummy perl dir
    $Conf->set_conf( buildflags => "install_base=$Lib" );
    
    ### don't start sending test reports now... ###
    $CB->_callbacks->send_test_report( sub { 0 } );
    $Conf->set_conf( cpantest => 0 );
    
    ### we dont need sudo -- we're installing in our own sandbox now
    $Conf->set_program( sudo => undef );
}

use_ok( $Class );

ok( $Class->format_available,   "Format is available" );


while( my($path,$need_cc) = each %Map ) {

    ### create a fake object, so we don't use the actual module tree
    my $mod = CPANPLUS::Module::Fake->new(
                    module  => 'Foo::Bar',
                    path    => 'src',
                    author  => CPANPLUS::Module::Author::Fake->new,
                    package => 'Foo-Bar-0.01.tar.gz',
                );

    ok( $mod,                   "Module object created for '$path'" );        
                
    ### set the fetch location -- it's local
    {   my $where = File::Spec->rel2abs(
                            File::Spec->catdir( $Src, $path, $mod->package )
                        );
                        
        $mod->status->fetch( $where );

        ok( -e $where,          "   Tarball '$where' exists" );
    }

    ok( $mod->prepare,          "   Preparing module" );

    ok( $mod->status->dist_cpan,    
                                "   Dist registered as status" );

    isa_ok( $mod->status->dist_cpan, $Class );

    ok( $mod->status->dist_cpan->status->prepared,
                                "   Prepared status registered" );
    is( $mod->status->dist_cpan->status->distdir, $mod->status->extract,
                                "   Distdir status registered properly" );


    is( $mod->status->installer_type, INSTALLER_BUILD, 
                                "   Proper installer type found" );


    ### we might not have a C compiler
    SKIP: {
        skip("The CC compiler listed in Config.pm is not available " .
             "-- skipping compile tests", 5) if $need_cc && !$Have_CC;

        ok( $mod->create( ),    "Creating module" );
        ok( $mod->status->dist_cpan->status->created,
                                "   Created status registered" );

        ### install tests
        SKIP: {
            skip("Install tests require Module::Build 0.2606 or higher", 2)
                unless $Module::Build::VERSION >= '0.2606';
        
            ### flush the lib cache
            ### otherwise, cpanplus thinks the module's already installed
            ### since the blib is already in @INC
            $CB->_flush( list => [qw|lib|] );
        
            ### force the install, make sure the Dist::Build->install()
            ### sub gets called
            ok( $mod->install( force => 1 ),
                                "Installing module" ); 
            ok( $mod->status->installed,    
                                "   Status says module installed" );

        }

        SKIP: {
            skip(q[Can't uninstall: Module::Build writes no .packlist], 1);
        
            ### XXX M::B doesn't seem to write into the .packlist...
            ### can't figure out what to uninstall then...
            ok( $mod->uninstall,"Uninstalling module" );
        }
    }

    ### throw away all the extracted stuff
    $Utils->_rmdir( dir => $Conf->get_conf('base') );
}

# Local variables:
# c-indentation-style: bsd
# c-basic-offset: 4
# indent-tabs-mode: nil
# End:
# vim: expandtab shiftwidth=4:
