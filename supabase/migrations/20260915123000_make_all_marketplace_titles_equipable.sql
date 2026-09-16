-- All five current marketplace items are profile titles and can be equipped.
update public.marketplace_items
set
  kind = 'title',
  cosmetic_value = case name
    when 'Neon Mint' then 'Neon Mint'
    when 'Electric Blue' then 'Electric Blue'
    when 'Royal Gold' then 'Royal Gold'
    else cosmetic_value
  end,
  updated_at = now()
where name in ('Neon Mint', 'Electric Blue', 'Royal Gold')
  and active = true;
