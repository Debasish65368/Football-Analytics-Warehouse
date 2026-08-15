select * from dim_team;

select m.* 
from fact_matches m
join dim_division d on m.division_key = d.division_key
where d.division_name = 'ROM';

select * from fact_matches WHERE ft_home_goals is null;

-- select * from avg_goals_per_team;
