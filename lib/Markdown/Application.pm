#!/usr/bin/perl -w
#
# Steve
# --
#



use strict;
use warnings;

package Markdown::Application;
use base 'CGI::Application';


#
#  Standard modules
#
use HTML::Template;
use Math::Base36 ':all';
use Redis;
use Text::Markdown 'markdown';




#
# Called before CGI::App dispatches to a runmode, merge GET + POST
# parameters.
#
# Source:
#  * http://www.perlmonks.org/?node_id=748939
#
sub cgiapp_prerun
{
    my ($self) = @_;

    # $self->mode_param so we don't have to go back and change this if we
    # ever decide to use something other than rm
    if ($self->query->url_param($self->mode_param))
    {
        # prerun_mode lets you change CGI::Apps notion of the current runmode
        $self->prerun_mode($self->query->url_param($self->mode_param));
    }
    return;
}



=begin doc

Setup our run-mode mappings, and the defaults for the application.

=end doc

=cut

sub setup
{
    my $self = shift;

    $self->run_modes(

        # Handlers
        'index'  => 'index',
        'create' => 'create',
        'view'   => 'view',

        # called on unknown mode.
        'AUTOLOAD' => 'unknown_mode',
    );

    #
    #  Start mode + mode name
    #
    $self->header_add(-charset => 'utf-8');
    $self->start_mode('index');
    $self->mode_param('mode');
}



=begin doc

Redirect to the given URL.

=end doc

=cut

sub redirectURL
{
    my ( $self, $url ) = (@_);

    $self->header_add( -location => $url,
                       -status   => "302",
                     );
    $self->header_type('redirect');
    return "";

}



=begin doc

Load a template from our ./templates directory - which is outside the
web root directory for safety.

=end doc

=cut


sub load_template
{
    my ( $self, $file, %options ) = (@_);

    my $path = "";

    foreach my $dir (qw! ../templates/ ../../templates/ !)
    {
        $path = $dir if ( -d $dir );
    }
    die "No path" unless ( defined($path) );

    my $template = HTML::Template->new( filename => $file,
                                        path     => [$path],
                                        %options,
                                        die_on_bad_params => 0,
                                      );
    return ($template);
}


=begin doc

Show the index page.

=end doc

=cut

sub index
{
    my ($self) = (@_);

    #
    #  Load the default index.
    #
    my $template = $self->load_template("index.tmpl");
    return ( $template->output() );
}



=begin doc

Create a new paste.

=end doc

=cut

sub create
{
    my ($self) = (@_);

    my $cgi  = $self->query();
    my $sub  = $cgi->param( "submit" );
    my $txt  = $cgi->param( "text" ) || "";


    #
    #  If we accept application/json.
    #
    foreach my $accept ( $cgi->Accept() )
    {
        if ( $accept =~ /application\/json/i )
        {
            #
            #  If we have TEXT submitted.
            #
            if ( $txt )
            {
                #
                #  Save it.
                #
                my $id = $self->saveMarkdown( $txt );

                #
                #  Build up the redirect link.
                #
                my $url = "http://" . $ENV{'SERVER_NAME'} . "/view/" . $id;
                return( "{\"id\":\"$id\",\"link\":\"$url\"}" );
            }
            else
            {


                $self->header_props( -status => 404 );
                return "Missing TEXT parameter";
            }
        }
    }


    #
    #  Load the output template
    #
    my $template = $self->load_template("create.tmpl");

    #
    #
    #
    if ( $sub && ( $sub =~ /preview/i ) )
    {
        #
        #  Render the text
        #
        my $html = render($txt);

        #
        #  Populate both the text and the HTML
        #
        $template->param( html => $html,
                          content => $txt,
                        );
    }
    elsif ( $sub && ( $sub =~ /create/i ) )
    {
        #
        #  Return
        #
        my $id = $self->saveMarkdown( $txt );
        return( $self->redirectURL( "/view/" . $id  ) );
    }

    return ( $template->output() );
}


=begin doc

Show the contents of a paste.

=end doc

=cut

sub view
{
    my ($self) = (@_);

    my $cgi  = $self->query();
    my $id   = $cgi->param( "id" );
    my $uid  = decode_base36($id);

    #
    #  Get the ID from Redis.
    #
    my $redis = Redis->new();
    my $text  = $redis->get( "MARKDOWN:$uid:TEXT" );
    $text = render( $text );

    #
    #  Return it
    #
    my $template = $self->load_template("view.tmpl");
    $template->param( html => $text, id => $id );

    return( $template->output() );
}


=begin doc

Render the text.

=end doc

=cut

sub render
{
    my ( $txt ) = (@_ );
    return( markdown( $txt ) );
}


=begin doc

Populate the given text in the next ID.

=end doc

=cut

sub saveMarkdown
{
    my( $self, $txt ) = ( @_ );

    #
    #  Create the ID
    #
    my $redis = Redis->new();
    my $id    = $redis->incr( "MARKDOWN:COUNT" );

    #
    #  Set the text
    #
    $redis->set( "MARKDOWN:$id:TEXT" , $txt );

    return( encode_base36( $id ) );
}



=begin doc

Called when an unknown mode is encountered.

=end doc

=cut

sub unknown_mode
{
    my ( $self, $requested ) = (@_);

    return ("mode not found $requested");
}




1;


