use v5.36;
use FindBin '$Bin';
use lib '../lib', 'lib';
use blib;
use lib $Bin;
use Carp  qw[croak];
use Affix qw[Int UInt32];
use SDL3  qw[:all];
use Data::Dump;
$|++;

# Another simple game. This time a quick platformer to demonstrate gamepad support.
#
# Powerups:
#  - Speed boost (blue)
#  - Jump boost (yellow)
#
# Controls (Requires a gamepad; I'm using an Xbox One controller):
#  - Move left/right with the left joystick
#  - Hit 'A' to jump
#
# TODO: See #2
#
# Config
my $SCREEN_W   = 800;
my $SCREEN_H   = 600;
my $GRAVITY    = 0.5;
my $JUMP_FORCE = -12.0;
my $MOVE_SPEED = 6.0;
my $DEADZONE   = 8000;

# Init
SDL_Init( SDL_INIT_VIDEO | SDL_INIT_GAMEPAD ) || die 'Init Error: ' . SDL_GetError();
my $win       = SDL_CreateWindow( 'Scalar Sprint', $SCREEN_W, $SCREEN_H, 0 );
my $ren       = SDL_CreateRenderer( $win, undef, 0 );
my $event_ptr = Affix::malloc(128);

# Gamepad State
my $gamepad      = undef;
my $gamepad_id   = -1;
my $gamepad_name = 'No Controller';

sub open_controller ($id) {
    return                     if $gamepad_id == $id;    # If we already have this specific controller, skip
    SDL_CloseGamepad($gamepad) if $gamepad;              # If we have a DIFFERENT controller, close it first
    my $new_pad = SDL_OpenGamepad($id);
    if ($new_pad) {
        $gamepad      = $new_pad;
        $gamepad_id   = SDL_GetGamepadID($new_pad);
        $gamepad_name = SDL_GetGamepadName($new_pad);
        say "Controller Connected: $gamepad_name (Instance: $gamepad_id)";
    }
}

# Startup Probe
my $count_ptr = Affix::calloc( 1, Int );
my $list_ptr  = SDL_GetGamepads($count_ptr);
open_controller( Affix::cast( $list_ptr, UInt32 ) ) if Affix::cast( $count_ptr, Int ) > 0;
SDL_free($list_ptr)                                 if $list_ptr;
Affix::free($count_ptr);

# Game Objects
my $camera_x  = 0;
my $score     = 0;
my $game_over = 0;
my $player    = { x => 100, y => 300, w => 40, h => 40, vx => 0, vy => 0, grounded => 0 };
my %effects   = ( speed => 0, jump => 0 );
my @platforms;
my @pickups;

sub draw_centered_text ( $y, $text ) {
    my $x = ( $SCREEN_W - ( length($text) * 8 ) ) / 2;
    SDL_RenderDebugText( $ren, $x, $y, $text );
}

sub reset_game {
    $player->{x}  = 100;
    $player->{y}  = 300;
    $player->{vx} = 0;
    $player->{vy} = 0;
    $camera_x     = 0;
    $score        = 0;
    $game_over    = 0;
    %effects      = ( speed => 0, jump => 0 );
    @platforms    = ();
    @pickups      = ();
    push @platforms, { x => 0, y => 400, w => 800, h => 200 };
}
reset_game();

sub spawn_platform ($last_x) {
    my $gap    = 100 + int( rand(100) );
    my $width  = 200 + int( rand(300) );
    my $height = 50 + int( rand(150) );
    my $y      = 300 + int( rand(200) );
    my $new_x  = $last_x + $gap;
    push @platforms, { x => $new_x, y => $y, w => $width, h => $height };
    if ( rand() > 0.7 ) {
        my $type = ( rand() > 0.5 ) ? 'speed' : 'jump';
        push @pickups, { x => $new_x + $width / 2 - 15, y => $y - 60, w => 30, h => 30, type => $type };
    }
}

sub check_aabb ( $a, $b ) {
    return !( $a->{x} + $a->{w} < $b->{x} || $a->{x} > $b->{x} + $b->{w} || $a->{y} + $a->{h} < $b->{y} || $a->{y} > $b->{y} + $b->{h} );
}

# Loop
my $running   = 1;
my $last_time = SDL_GetTicks();
while ($running) {
    my $current_time = SDL_GetTicks();
    my $delta        = ( $current_time - $last_time ) / 16.0;
    if ( $delta > 4 ) { $delta = 4; }
    $last_time = $current_time;

    # Instead of relying on REMOVED events, we ask the pointer if it's valid.
    if ($gamepad) {
        if ( SDL_GamepadConnected($gamepad) == 0 ) {    # It's gone!
            SDL_CloseGamepad($gamepad);
            $gamepad      = undef;
            $gamepad_id   = -1;
            $gamepad_name = 'Disconnected';
            say 'Controller Disconnected (Connection Lost)';
        }
    }

    # Events
    while ( SDL_PollEvent($event_ptr) ) {
        my $h = Affix::cast( $event_ptr, SDL_CommonEvent );
        if ( $h->{type} == SDL_EVENT_QUIT ) { $running = 0; }

        # We still listen for ADDED to support hotplugging new ones
        elsif ( $h->{type} == SDL_EVENT_GAMEPAD_ADDED ) {
            my $g = Affix::cast( $event_ptr, SDL_GamepadDeviceEvent );
            open_controller( $g->{which} );
        }

        # Ignore REMOVED event to prevent ID collisions
        elsif ( $h->{type} == SDL_EVENT_KEY_DOWN ) {
            my $k = Affix::cast( $event_ptr, SDL_KeyboardEvent );
            if ( $game_over && $k->{scancode} == SDL_SCANCODE_R ) { reset_game(); }
        }
    }
    unless ($game_over) {
        my $input_x      = 0.0;
        my $jump_pressed = 0;
        if ($gamepad) {
            my $axis = SDL_GetGamepadAxis( $gamepad, SDL_GAMEPAD_AXIS_LEFTX );
            if ( abs($axis) > $DEADZONE )                                     { $input_x      = $axis / 32767.0; }
            if ( SDL_GetGamepadButton( $gamepad, SDL_GAMEPAD_BUTTON_SOUTH ) ) { $jump_pressed = 1; }
        }

        # Physics
        my $speed_mult = ( $effects{speed} > 0 ) ? 1.8 : 1.0;
        $player->{vx} = $input_x * $MOVE_SPEED * $speed_mult;
        if ( $jump_pressed && $player->{grounded} ) {
            $player->{vy}       = $JUMP_FORCE * ( $effects{jump} > 0 ? 1.5 : 1.0 );
            $player->{grounded} = 0;
        }
        $player->{vy} += $GRAVITY * $delta;
        $player->{x}  += $player->{vx} * $delta;
        $player->{y}  += $player->{vy} * $delta;
        $player->{grounded} = 0;
        for my $plat (@platforms) {
            if ( check_aabb( $player, $plat ) ) {
                if ( $player->{vy} > 0 && ( $player->{y} - $player->{vy} * $delta ) + $player->{h} <= $plat->{y} + 15 ) {
                    $player->{y}        = $plat->{y} - $player->{h};
                    $player->{vy}       = 0;
                    $player->{grounded} = 1;
                }
            }
        }
        for my $i ( reverse 0 .. $#pickups ) {
            if ( check_aabb( $player, $pickups[$i] ) ) {
                $effects{ $pickups[$i]->{type} } = 300;
                splice( @pickups, $i, 1 );
            }
        }
        for my $k ( keys %effects ) {
            if ( $effects{$k} > 0 ) { $effects{$k} -= $delta; }
        }
        if ( $player->{x} > $score ) { $score = int( $player->{x} ); }
        my $target_cam = $player->{x} - 200;
        if ( $camera_x < $target_cam ) { $camera_x = $target_cam; }
        my $last = $platforms[-1];
        if ( $last->{x} < $camera_x + $SCREEN_W + 200 )                  { spawn_platform( $last->{x} + $last->{w} ); }
        if ( $platforms[0]->{x} + $platforms[0]->{w} < $camera_x - 100 ) { shift @platforms; }
        if ( $player->{y} > $SCREEN_H )                                  { $game_over = 1; }
    }

    # Render
    SDL_SetRenderDrawColor( $ren, 30, 30, 40, 255 );
    SDL_RenderClear($ren);
    SDL_SetRenderDrawColor( $ren, 100, 100, 120, 255 );
    for my $p (@platforms) {
        SDL_RenderFillRect( $ren, { x => $p->{x} - $camera_x, y => $p->{y}, w => $p->{w}, h => $p->{h} } );
    }
    for my $p (@pickups) {
        if   ( $p->{type} eq 'speed' ) { SDL_SetRenderDrawColor( $ren, 0,   100, 255, 255 ); }
        else                           { SDL_SetRenderDrawColor( $ren, 255, 200, 0,   255 ); }
        SDL_RenderFillRect( $ren, { x => $p->{x} - $camera_x, y => $p->{y}, w => $p->{w}, h => $p->{h} } );
    }
    if    ( $effects{speed} > 0 ) { SDL_SetRenderDrawColor( $ren, 0,   200, 255, 255 ); }
    elsif ( $effects{jump} > 0 )  { SDL_SetRenderDrawColor( $ren, 255, 255, 0,   255 ); }
    else                          { SDL_SetRenderDrawColor( $ren, 0,   255, 0,   255 ); }
    SDL_RenderFillRect( $ren, { x => $player->{x} - $camera_x, y => $player->{y}, w => $player->{w}, h => $player->{h} } );
    SDL_SetRenderDrawColor( $ren, 255, 255, 255, 255 );
    SDL_RenderDebugText( $ren, 10, 10, "Score: $score" );
    SDL_RenderDebugText( $ren, 10, 30, "Controller: $gamepad_name" );

    if ($game_over) {
        SDL_SetRenderDrawColor( $ren, 255, 0, 0, 255 );
        draw_centered_text( ( $SCREEN_H / 2 ) - 4, 'GAME OVER' );
    }
    SDL_RenderPresent($ren);
    SDL_Delay(16);
}
SDL_CloseGamepad($gamepad) if $gamepad;
Affix::free($event_ptr);
SDL_DestroyRenderer($ren);
SDL_DestroyWindow($win);
SDL_Quit();
