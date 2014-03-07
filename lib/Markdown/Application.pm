# -*- cperl -*- #

=head1 NAME

Markdown::Application - A CGI::Application .. application

=head1 DESCRIPTION

This module implements is a web application, built using L<CGI::Application>,
which allows the sharing and rendering of Markdown text.

Remote users can upload Markdown text, and when they do so they will
recieve a stable/static URL which can be shared.  That URL will allow
later visitors to either view the rendered markdown, or the raw text.

In addition to allowing user-uploads there are a small number of static
endpoints defined which will show pre-cooked markdown text.

=cut

=head1 IMPLEMENTATION NOTES

When a piece of text is uploaded then it is pushed into a redis database,
and at the same time an authentication token is generated.

The intention is that only the uploader knows the authentication token,
and that token is required to edit/remove the text in the future.

* When posts are created they are given UUIDs to avoid enumeration.
    * This will allow http://host/view/xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx
* When a post is created it will have a token created allowing:
    * http://host/edit/$token
    * http://host/delete/$token

The token is a one-to-one mapping, again stored in our redis store.  So
given an ID ("xxxxxx-xxxx-...") and a TOKEN ( "1234" ) we merely run:

    redis->set( "MARKDOWN:KEY:$TOKEN", $ID )

This allows us to lookup the ID given the TOKEN, but not vice-versa, since
that shouldn't be required.

=cut

=head1 AUTHOR

Steve Kemp <steve@steve.org.uk>

=cut

=head1 COPYRIGHT AND LICENSE

Copyright (C) 2014 Steve Kemp <steve@steve.org.uk>.

This library is free software. You can modify and or distribute it under
the same terms as Perl itself.

=cut




use strict;
use warnings;

#
# Hierarchy
#
package Markdown::Application;
use base 'Markdown::Application::Base';


#
# Standard module(s)
#
use Data::UUID;
use Digest::MD5 qw(md5_hex);
use JSON;
use HTML::Emoji;
use HTML::Template;
use Math::Base36 ':all';
use Text::MultiMarkdown 'markdown';




=begin doc

Setup our run-mode mappings, and the defaults for the application.

=end doc

=cut

sub setup
{
    my $self = shift;

    $self->run_modes(

        # Static-page Handlers
        'api'   => sub {showStatic( $self, 'api.tmpl' )},
        'cheat' => sub {showStatic( $self, 'cheat.tmpl' )},
        'faq'   => sub {showStatic( $self, 'faq.tmpl' )},
        'index' => sub {showStatic( $self, 'index.tmpl' )},

        # Real handlers.
        'create' => 'create',
        'delete' => 'delete',
        'edit'   => 'edit',
        'raw'    => 'raw',
        'view'   => 'view',

        # called on unknown mode.
        'AUTOLOAD' => 'unknown_mode',
    );

    #
    #  Start mode + mode name
    #
    $self->header_add( -charset => 'utf-8' );
    $self->start_mode('index');
    $self->mode_param('mode');
}




=begin doc

Show a static page.

=end doc

=cut

sub showStatic
{
    my ( $self, $page ) = (@_);

    my $template = $self->load_template($page);

    my $cgi = $self->query();
    my $url = $cgi->url( -base => 1 );
    $template->param( domain => $url );

    return ( $template->output() );
}



=begin doc

Create a new paste.

=end doc

=cut

sub create
{
    my ($self) = (@_);

    my $cgi = $self->query();
    my $sub = $cgi->param("submit");
    my $txt = $cgi->param("text") || "";


    #
    #  See if the caller accepts "application/json", and handle
    # that first - this is suboptimal and should be merged in better
    # later on.
    #
    foreach my $accept ( $cgi->Accept() )
    {
        if ( $accept =~ /application\/json/i )
        {

            #
            #  If we have TEXT submitted.
            #
            if ( $txt && length($txt) )
            {

                #
                #  Save it.
                #
                my $id = $self->saveMarkdown($txt);

                #
                #  Get the token for the deletion/edit link.
                #
                my $auth = $self->gen_token($id);

                #
                # Build up something sensible to return to the caller
                #
                # At the least they need to know:
                #
                #   * The ID.
                #   * The view-link.
                #   * The raw-link.
                #   * The delete-link.
                #
                my $base = $cgi->url( -base => 1 );

                my %hash;
                $hash{ "id" }     = $id;
                $hash{ "link" }   = $base . "/view/" . $id;
                $hash{ "raw" }    = $base . "/raw/" . $id;
                $hash{ "delete" } = $base . "/delete/" . $auth;

                #
                #  Return the JSON object.
                #
                return to_json( \%hash );
            }
            else
            {

                #
                # We'll handle this better later.
                #
                $self->header_props( -status => 404 );
                return "Missing TEXT parameter";
            }
        }
    }


    #
    #  OK at this point we have a browser-based submission,
    # with no acceptance of "application/json".
    #
    #  Proceed as per usual.
    #

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
        if ( length($txt) )
        {
            my $html = render($txt);

            #
            #  Populate both the text and the HTML
            #
            $template->param( html    => $html,
                              content => $txt, );
        }
    }
    elsif ( $sub &&
            ( $sub =~ /create/i ) &&
            length($txt) )
    {

        #
        #  Get the ID of the newly submitted entry.
        #
        my $id = $self->saveMarkdown($txt);

        #
        #  Create a deletion link.
        #
        my $auth = $self->gen_token($id);

        #
        #  Set the session-flash parameter with the secret ID.
        #
        my $session = $self->param('session');
        if ($session)
        {
            $session->param( "flash", $auth );
        }

        #
        #  Redirect to view the new submission.
        #
        return ( $self->redirectURL( "/view/" . $id ) );
    }

    return ( $template->output() );
}


=begin doc

Edit a prior submission, via a token.

=end doc

=cut

sub edit
{
    my ($self) = (@_);

    #
    #  Get the ID
    #
    my $cgi = $self->query();
    my $id  = $cgi->param("id");

    #
    # If there's a missing ID redirect.  If the ID is bogus abort.
    #
    return ( $self->redirectURL("/") ) unless ($id);
    die "Invalid ID" unless ( $id =~ /^([-a-z0-9]+)$/i );

    #
    #  Find the value, and see if it exists
    #
    my $redis = $self->{ 'redis' };
    my $rid   = $redis->get("MARKDOWN:KEY:$id");

    #
    #  If the value is not present then abort
    #
    if ( ( !$rid ) ||
         ( $rid !~ /^([-0-9a-z]+)$/i ) )
    {
        $self->header_props( -status => 404 );
        return "Invalid auth-key!  (Has the post has been deleted?)";
    }

    #
    ##
    ##  Ok we can load the text and allow the preview-stuff to happen.
    ##
    #

    #
    # If we have a legacy ID then decode, otherwise use as-is.
    #
    my $did = $rid;
    if ( length($did) < 3 )
    {
        $did = decode_base36($id);
    }

    #
    #  Load the template
    #
    my $template = $self->load_template("edit.tmpl");

    #
    #  See if the user is submitting
    #
    my $submit = $cgi->param("submit");

    if ( $submit && ( $submit =~ /preview/i ) )
    {
        my $text = $cgi->param("text");

        #
        #  Render the text
        #
        if ( length($text) )
        {
            my $html = render($text);

            #
            #  Populate both the text and the HTML
            #
            $template->param( html    => $html,
                              id      => $id,
                              content => $text
                            );
        }
    }
    elsif ( $submit && ( $submit =~ /save/i ) )
    {

        #
        #  Get the text, and save it.
        #
        my $text = $cgi->param("text");
        $redis->set( "MARKDOWN:$did:TEXT", $text );

        #
        #  Redirect to view it.
        #
        return ( $self->redirectURL( "/view/" . $rid ) );

    }
    else
    {
        $template->param( content => $redis->get("MARKDOWN:$did:TEXT"),
                          id      => $id, );
    }

    return ( $template->output() );
}


=begin doc

Delete a prior-upload by ID.

=end doc

=cut

sub delete
{
    my ($self) = (@_);

    #
    #  Get the ID
    #
    my $cgi = $self->query();
    my $id  = $cgi->param("id");

    #
    # If there's a missing ID redirect.  If the ID is bogus abort.
    #
    return ( $self->redirectURL("/") ) unless ($id);
    die "Invalid ID" unless ( $id =~ /^([-a-z0-9]+)$/i );

    #
    #  Find the value, and see if it exists
    #
    my $redis = $self->{ 'redis' };
    my $rid   = $redis->get("MARKDOWN:KEY:$id");

    #
    #  If the value is present
    #
    if ( $rid && ( $rid =~ /^([-0-9a-z]+)$/i ) )
    {

        #
        # If we have a legacy ID then decode, otherwise use as-is.
        #
        my $did = $rid;
        if ( length($did) < 3 )
        {
            $did = decode_base36($id);
        }

        #
        #  Unset the text
        #
        $redis->set( "MARKDOWN:$did:TEXT", "" );

        #
        #  Remove the auth-key.
        #
        $redis->del("MARKDOWN:KEY:$id");

        #
        #  Remove this ID from the recent list of valid IDs, if present.
        #
        $redis->lrem( "MARKDOWN:RECENT", 1, $did );

        return ( $self->redirectURL( "/view/" . $rid ) );
    }
    else
    {
        $self->header_props( -status => 404 );
        return "Invalid auth-key!  (Has the post already been deleted?)";
    }
}



=begin doc

Show the contents of a paste.

=end doc

=cut

sub view
{
    my ($self) = (@_);

    #
    #  Is there a flash message?
    #
    my $flash = undef;

    #
    #  Possibly from the session.
    #
    my $session = $self->param('session');
    if ( $session &&
         $session->param("flash") &&
         length( $session->param("flash") ) )
    {

        # get the flash
        $flash = $session->param("flash");

        # empty?
        if ( length($flash) )
        {
            $session->param( "flash", "" );
        }
        else
        {
            $flash = undef;
        }

    }

    #
    #  Get the ID
    #
    my $cgi = $self->query();
    my $id  = $cgi->param("id");

    #
    # If there's a missing ID redirect.  If the ID is bogus abort.
    #
    return ( $self->redirectURL("/") ) unless ($id);
    die "Invalid ID" unless ( $id =~ /^([-a-z0-9]+)$/i );

    #
    #  Decode and get the text.
    #
    #
    # If we have a legacy ID then decode, otherwise use as-is.
    #
    my $uid = $id;
    if ( length($id) < 3 )
    {
        $uid = decode_base36($id);
    }

    #
    #  Get the text
    #
    my $redis = $self->{ 'redis' };
    my $text  = $redis->get("MARKDOWN:$uid:TEXT");

    #
    #  Increase the view-count
    #
    $redis->incr("MARKDOWN:$uid:VIEWED");


    #
    # Load the template
    #
    my $template = $self->load_template("view.tmpl");

    #
    #  If we have the text then render it.
    #
    if ( defined($text) && length($text) )
    {
        $text = render($text);
        $template->param( html => $text );
    }
    else
    {

        # Look for a local copy
        if ( $uid =~ /^([a-z]+)$/ )
        {
            $text = $self->loadFile("samples/$uid.md");
            if ($text)
            {
                $text = render($text);
                $template->param( html => $text );
            }
        }
    }


    #
    # Render.
    #
    $template->param( id => $id );
    $template->param( flash => $flash ) if ($flash);
    return ( $template->output() );
}



=begin doc

Show the contents of a paste, as raw markdown.

=end doc

=cut

sub raw
{
    my ($self) = (@_);

    #
    #  Get the ID
    #
    my $cgi = $self->query();
    my $id  = $cgi->param("id");

    #
    # If there's a missing ID redirect.  If the ID is bogus abort.
    #
    return ( $self->redirectURL("/") ) unless ($id);
    die "Invalid ID" unless ( $id =~ /^([-a-z0-9]+)$/i );

    #
    # If we have a legacy ID then decode, otherwise use as-is.
    #
    my $uid = $id;
    if ( length($id) < 3 )
    {
        $uid = decode_base36($id);
    }

    my $redis = $self->{ 'redis' };
    my $text  = $redis->get("MARKDOWN:$uid:TEXT");

    if ( !$text )
    {

        # Look for a local copy
        if ( $uid =~ /^([a-z]+)$/ )
        {
            $text = $self->loadFile("samples/$uid.md");
        }
    }

    if ( length($text) )
    {
        $self->header_add( '-type' => 'text/plain' );
        return ($text);
    }
    else
    {
        $self->header_props( -status => 404 );
        return "Not found";
    }

}



=begin doc

Render the given markdown text, handling emoji expansion too.

B<NOTE> All our code passes the markdown through this method to ensure that
we only need to update the rendering process in one place.

=end doc

=cut

sub render
{
    my ($txt) = (@_);

    #
    # Convert to HTML
    #
    my $html = markdown($txt);

    #
    # Now we have HTML we can process the content for known-emojis too.
    #
    my $helper = HTML::Emoji->new( path => "/img/emojis" );

    return ( $helper->expand($html) );

}


=begin doc

Save the given text in our store, and return the globally unique
identifier for it.

=end doc

=cut

sub saveMarkdown
{
    my ( $self, $txt ) = (@_);

    #
    #  Create the ID, which will hopefully avoid collisions.
    #
    my $helper = Data::UUID->new();
    my $id     = $helper->create_str();

    #
    #  We want to ensure that we don't collide.
    #
    my $redis = $self->{ 'redis' };
    while ( defined( $redis->get($id) ) )
    {

        #
        #  Regenerate
        #
        $id = $helper->create_str();
    }

    #
    #  Set the text
    #
    $redis->set( "MARKDOWN:$id:TEXT", $txt );

    #
    #  Store the most recently used IDs.
    #
    $redis->rpush( "MARKDOWN:RECENT", $id );
    $redis->ltrim( "MARKDOWN:RECENT", 0, 99 );

    return ($id);
}


=begin doc

Create an authentication token for a given ID.

We could use a UUID here, but to give it a different feel I used a hash
of the time, the remote IP, and some "randomness".  Hrm.

=end doc

=cut

sub gen_token
{
    my ( $self, $id ) = (@_);

    my $cgi = $self->query();

    #
    #  The authentication token is "hash( time, ip, id )";
    #
    my $key = time . $cgi->remote_host() . $id;

    #
    # Add some more random data.
    #
    $key .= int( rand(1000) );
    $key .= int( rand(1000) );

    #
    # Make it URL-safe
    #
    my $digest = md5_hex($key);

    #
    # Set the value
    #
    my $redis = $self->{ 'redis' };
    $redis->set( "MARKDOWN:KEY:$digest", $id );
    return ($digest);
}




1;


