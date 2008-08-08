#  You may distribute under the terms of either the GNU General Public License
#  or the Artistic License (the same terms as Perl itself)
#
#  (C) Paul Evans, 2008 -- leonerd@leonerd.org.uk

package Net::Async::HTTP;

use strict;

our $VERSION = '0.01';

use Carp;

use Net::Async::HTTP::Client;

use HTTP::Request;
use HTTP::Request::Common qw();

use Socket qw( SOCK_STREAM );

=head1 NAME

C<Net::Async::HTTP> - Asynchronous HTTP user agent

=head1 SYNOPSIS

 use IO::Async::Loop::...;
 use Net::Async::HTTP;
 use URI;

 my $loop = IO::Async::Loop::...;

 my $http = Net::Async::HTTP->new( loop => $loop );

 $http->do_request(
    uri => URI->new( "http://www.cpan.org/" ),

    on_response => sub {
       my ( $response ) = @_;
       print "Front page of http://www.cpan.org/ is:\n";
       print $response->as_string;
       $loop->loop_stop;
    },

    on_error => sub {
       my ( $message ) = @_;
       print "Cannot fetch http://www.cpan.org/ - $message\n";
       $loop->loop_stop;
    },
 );

 $loop->loop_forever;

=head1 DESCRIPTION

This object class implements an asynchronous HTTP user agent. It sends
requests to servers, and invokes continuation callbacks when responses are
received. The object supports multiple concurrent connections to servers, and
allows multiple outstanding requests in pipeline to any one connection.
Normally, only one such object will be needed per program to support any
number of requests.

=cut

=head1 CONSTRUCTOR

=cut

=head2 $http = Net::Async::HTTP->new( %args )

This function returns a new instance of a C<Net::Async::HTTP> object. It takes
the following named arguments:

=over 8

=item loop => IO::Async::Loop

A reference to an C<IO::Async::Loop> object.

=item user_agent => STRING

A string to set in the C<User-Agent> HTTP header. If not supplied, one will
be constructed that declares C<Net::Async::HTTP> and the version number.

=back

=cut

sub new
{
   my $class = shift;
   my %args = @_;

   my $loop = delete $args{loop} or croak "Need a 'loop'";

   my $self = bless {
      loop => $loop,

      connections => {}, # { "$host:$port" } -> [ $conn, @pending_onread ]

      user_agent => defined $args{user_agent} ? $args{user_agent}
                                              : "Perl + " . __PACKAGE__ . "/$VERSION",
   }, $class;

   return $self;
}

=head1 METHODS

=cut

sub get_connection
{
   my $self = shift;
   my %args = @_;

   my $on_ready = $args{on_ready} or croak "Expected 'on_ready' as a CODE ref";
   my $on_error = $args{on_error} or croak "Expected 'on_error' as a CODE ref";

   my $loop = $self->{loop};

   my $host = $args{host};
   my $port = $args{port};

   if( my $cr = $self->{connections}->{"$host:$port"} ) {
      my ( $conn ) = @$cr;

      my $on_read = $on_ready->( $conn );
      push @$cr, $on_read;

      return;
   }

   if( $args{handle} ) {
      my $on_read;

      my $cr;

      my $conn = Net::Async::HTTP::Client->new(
         handle => $args{handle},

         on_closed => sub {
            delete $self->{connections}->{"$host:$port"};
         },
      );

      $cr = $self->{connections}->{"$host:$port"} = [ $conn ];

      $loop->add( $conn );

      $on_read = $on_ready->( $conn );

      return;
   }

   $loop->connect(
      host     => $host,
      service  => $port,
      socktype => SOCK_STREAM,

      on_resolve_error => sub {
         $on_error->( "$host:$port not resolvable [$_[0]]" );
      },

      on_connect_error => sub {
         $on_error->( "$host:$port not contactable" );
      },

      on_connected => sub {
         my ( $sock ) = @_;
         $self->get_connection( %args, handle => $sock );
      },
   );
}

=head2 $http->do_request( %args )

Send an HTTP request to a server, and set up the callbacks to receive a reply.
The request may be represented by an C<HTTP::Request> object, or a C<URI>
object, depending on the arguments passed.

The following named arguments are used for C<HTTP::Request>s:

=over 8

=item request => HTTP::Request

A reference to an C<HTTP::Request> object

=item host => STRING

=item port => INT

Hostname and port number of the server to connect to

=back

The following named arguments are used for C<URI> requests:

=over 8

=item uri => URI

A reference to a C<URI> object

=item method => STRING

Optional. The HTTP method. If missing, C<GET> is used.

=item content => STRING

Optional. The body content to use for C<POST> requests.

=item user => STRING

=item pass => STRING

Optional. If both are given, the HTTP Basic Authorization header will be sent
with these details.

=item proxy_host => STRING

=item proxy_port => INT

Optional. Override the hostname or port number implied by the URI.

=back

For either request type, it takes the following continuation callbacks:

=over 8

=item on_response => CODE

A callback that is invoked when a response to this request has been received.
It will be passed an L<HTTP::Response> object containing the response the
server sent.

 $on_response->( $response )

=item on_error => CODE

A callback that is invoked if an error occurs while trying to send the request
or obtain the response. It will be passed an error message.

 $on_error->( $message )

=back

=cut

sub do_request
{
   my $self = shift;
   my %args = @_;

   my $on_response = $args{on_response} or croak "Expected 'on_response' as a CODE ref";
   my $on_error    = $args{on_error}    or croak "Expected 'on_error' as a CODE ref";

   my $request;

   my $host;
   my $port;

   if( $args{request} ) {
      $request = delete $args{request};
      ref $request and $request->isa( "HTTP::Request" ) or croak "Expected 'request' as a HTTP::Request reference";
   }
   elsif( $args{uri} ) {
      my $uri = delete $args{uri};
      ref $uri and $uri->isa( "URI" ) or croak "Expected 'uri' as a URI reference";

      my $method = delete $args{method} || "GET";

      $host = $uri->host;
      $port = $uri->port;
      my $path = $uri->path_query;

      $path = "/" if $path eq "";

      if( $method eq "POST" ) {
         # This will automatically encode a form for us
         $request = HTTP::Request::Common::POST( $path, Content => $args{content} );
      }
      else {
         $request = HTTP::Request->new( $method, $path );
      }

      $request->protocol( "HTTP/1.1" );
      $request->header( Host => $host );

      my ( $user, $pass );

      if( defined $uri->userinfo ) {
         ( $user, $pass ) = split( m/:/, $uri->userinfo, 2 );
      }
      elsif( defined $args{user} and defined $args{pass} ) {
         $user = $args{user};
         $pass = $args{pass};
      }

      if( defined $user and defined $pass ) {
         $request->authorization_basic( $user, $pass );
      }
   }

    $request->init_header( 'User-Agent' => $self->{user_agent} ) if length $self->{user_agent};

   if( $args{handle} ) { # INTERNAL UNDOCUMENTED
      $self->get_connection(
         handle => $args{handle},

         # To make the connection cache logic happy
         host => "[[local_io_handle]]",
         port => fileno $args{handle},

         on_error => $on_error,

         on_ready => sub {
            my ( $conn ) = @_;
            $conn->request(
               %args,
               request => $request,
            );
         },
      );
   }
   else {
      if( !defined $host ) {
         $host = delete $args{host} or croak "Expected 'host'";
      }

      if( !defined $port ) {
         $port = delete $args{port} or croak "Expected 'port'";
      }

      $self->get_connection(
         host => $args{proxy_host} || $host,
         port => $args{proxy_port} || $port,

         on_error => $on_error,

         on_ready => sub {
            my ( $conn ) = @_;
            $conn->request(
               %args,
               request => $request,
            );
         },
      );
   }
}

# Keep perl happy; keep Britain tidy
1;

__END__

=head1 SEE ALSO

=over 4

=item *

L<RFC 2616|http://tools.ietf.org/html/rfc2616> - Hypertext Transfer Protocol
-- HTTP/1.1

=back

=head1 AUTHOR

Paul Evans E<lt>leonerd@leonerd.org.ukE<gt>
