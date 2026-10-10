-- Release reservations for blackjack hands that finish during the initial deal.
-- Those sessions never transition through an UPDATE, so the existing release
-- trigger cannot otherwise remove their temporary loss reservation.
drop trigger if exists release_terminal_blackjack_loss_reservation on public.blackjack_sessions;
create trigger release_terminal_blackjack_loss_reservation
after insert on public.blackjack_sessions
for each row when (new.status <> 'active')
execute function private.release_game_loss_reservation();
