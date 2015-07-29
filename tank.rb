require 'net/http'
require 'uri'
require 'optparse'
require 'json'
require 'set'
require 'fc'

$opts = {}

OptionParser.new do |options|
  options.on("-nNAME", "--name=NAME", String) { |v| $opts[:name] = v }
  options.on("-hHOST", "--host=HOST", String) { |v| $opts[:host] = v }
  options.on("-pPORT", "--port=PORT", Integer) { |v| $opts[:port] = v }
  options.on("-gGAME", "--game=GAME", String) { |v| $opts[:game] = v }
end.parse!

unless $opts[:game]
  puts "specify --game"
  exit
end

$opts[:host] ||= 'localhost'
$opts[:port] ||= 8080
$opts[:name] ||= 'jps'
$http = Net::HTTP.new($opts[:host], $opts[:port])

$config = {}

class Tank
  MAX_FIRE_DISTANCE = 10      # don't fire from further away to reduce chances of evasion
  MIN_ENERGY_FRACTION = 0.25  # go into defensive mode if we have less total energy than this
  HYST_ENERGY_FRACTION = 0.80 # hysteresis value for returning to aggressive mode after collecting batteries
  MIN_HEALTH_FRACTION = 0.25  # avoid the enemy when health is below this point

  def connect
    puts "joining game #{$opts[:game]}"
    request = Net::HTTP::Post.new "/game/#{$opts[:game]}/join"
    request.add_field "X-Sm-Playermoniker", $opts[:name]
    response = $http.request(request)
    unless response.code.to_i == 200
      raise "bad response: #{response.inspect}"
    end
    @playerid = response['X-Sm-Playerid']
    status = JSON.parse response.body
    $config = status.delete('config')
    update_status(status)
  end

  def game_loop
    loop do
      status = do_something!
      break unless update_status(status)
    end
  end
  
  def do_something!
    action = fire!
    action ||= hunt_down_enemy
    action ||= collect_batteries
    action ||= cower_in_fear
    action ||= 'noop'
    submit_action action
  end

  # if enemy is in sight and we have the ability to fire, do it!
  def fire!
  	if @energy > 0 && enemy_in_crosshairs?
  	  @mode = "fire!"
  	  'fire'
  	end
  end

  # if health and energy are in a decent state, hunt down the enemy
  def hunt_down_enemy
    if @energy.to_f / $config['max_energy'].to_f >= (@mode == 'collect_batteries' ? HYST_ENERGY_FRACTION : MIN_ENERGY_FRACTION) &&
       @health.to_f / $config['max_health'].to_f >= MIN_HEALTH_FRACTION
      @mode = "hunt_down_enemy"
      move_toward @enemy
    end
  end

  # if a battery is present, go get one
  def collect_batteries
    unless @batts.empty?
      @mode = "collect_batteries"
      # if there are a lot of batteries, seek the geographically closest one
      # otherwise pick the closest path (around obstacles etc.)
      if @batts.size > 3
        batt = @batts.min_by { |batt| distance_to batt }
      else
        batt = @batts.min_by { |batt| path_length_to batt }
      end
      move_toward batt
    end
  end
    
  # seek cover
  def cower_in_fear
    @mode = "cower_in_fear"
    # ideally hide behind a wall, but that sounds really hard to implement!
    # for now just seek the furthest point on the board from the enemy
    # and _hope_ there's a wall in the way :P
    move_toward wrap_add(@enemy, @dimensions.map { |d| d / 2 })
  end

  def update_status(status)
    @status = status
    if @status['status'] != 'running'
      puts "game over: final status #{@status.inspect}"
      return false
    end
    @health = @status['health']
    @energy = @status['energy']
    @orientation = @status['orientation']
    parse_grid
    puts "my position: #{@pos.inspect} #{@orientation} / enemy position: #{@enemy.inspect} / energy: #{@energy} / health: #{@health}"
    true
  end

  def submit_action(action)
    puts "#{@mode} => #{action}"
    request = Net::HTTP::Post.new "/game/#{$opts[:game]}/#{action}"
    request.add_field "X-Sm-Playerid", @playerid
    response = $http.request(request)
    if response.code.to_i == 200
      JSON.parse response.body
    else
      raise "bad response: #{response.inspect}"
    end
  end

  def parse_grid
    @grid = @status['grid'].split("\n")
    @dimensions = [@grid.size, @grid[0].size]
    @lasers = []
    @batts  = []
    @grid.each_with_index do |line, row|
      line.chars.each_with_index do |char, col|
        case char
        when 'X'
          @pos = [row, col]
        when 'O'
          @enemy = [row, col]
        when 'L'
          @lasers << [row, col]
        when 'B'
          @batts << [row, col]
        end
      end
    end
  end

  def wrap_add(coords, delta)
    cr = coords.dup
    (0..1).each do |i|
      cr[i] = coords[i] + delta[i]
      cr[i] -= @dimensions[i] while cr[i] >= @dimensions[i]
      cr[i] += @dimensions[i] while cr[i] < 0
    end
    cr
  end
  
  def orientation_delta(orientation = @orientation, speed = 1)
  	case orientation
      when 'north' then [-speed, 0]
      when 'south' then [speed, 0]
      when 'west' then [0, -speed]
      when 'east' then [0, speed]
  	end
  end
  
  def orientation_axis(orientation = @orientation)
  	case orientation
      when 'north', 'south' then 0
      when 'west', 'east' then 1
  	end
  end
  
  def grid_at(coords)
    @grid[coords[0]][coords[1]]
  end
  
  # returns string of current field of vision
  def look_ahead(distance = nil)
    distance ||= @dimensions[orientation_axis]
    delta = orientation_delta
    coords = @pos.dup
    result = ''
    distance.times do
      coords = wrap_add(coords, delta)
      char = grid_at coords
      result << char
      break if char == 'W'
    end
    result
  end
  
  def enemy_in_crosshairs?
    puts "crosshairs: " + look_ahead(MAX_FIRE_DISTANCE)
    look_ahead(MAX_FIRE_DISTANCE) =~ /\A[_L]*O/
  end

  DIRS = ['north', 'west', 'south', 'east'] # ccw order

  def turn_direction(start_orientation, end_orientation)
  	si = DIRS.index(start_orientation)
  	di = DIRS.index(end_orientation)
    if (si + 1) % 4 == di
      'left'
    else
      'right' # possibly followed by another right, if we need a 180
    end  	
  end

  def turn_effect(start_orientation, turn)
    return start_orientation unless %w(right left).include? turn
    si = DIRS.index(start_orientation)
    DIRS[(si + ((turn == 'left') ? 1 : 3)) % 4]
  end

  def move_toward(coords)
    directions_to(coords).first
  end

  def path_length_to(coords)
  	directions_to(coords).length
  end

  def distance_to(coords)
    distance_between(@pos, coords)
  end

  def distance_between(from, to)
    (0..1).map { |axis| distance_on_axis(from[axis], to[axis], @dimensions[axis]) }.inject(:+)
  end

  # distance from `from` to `to`, possibly wrapping around
  def distance_on_axis(from, to, size)
    a, b = [from, to].sort
    [b - a, size + a - b].min
  end

  def directions_to(coords)
    directions_between(@pos, @orientation, coords)
  end

  # A*
  class State
    attr_accessor :position, :orientation, :history
    def initialize(position, orientation, history = [])
      self.position = position
      self.orientation = orientation
      self.history = history
    end
  end

  def directions_between(start_pos, start_orientation, goal_pos)
    return ['noop'] if start_pos == goal_pos
    priority = -> (state) { distance_between(state.position, goal_pos) + state.history.size }
    visited = Set.new
    queue = FastContainers::PriorityQueue.new(:min)
    start_state = State.new(start_pos, start_orientation)
    queue.push start_state, priority.(start_state)
    until queue.empty?
      state = queue.top; queue.pop
      if state.position == goal_pos
        # \o/
        return state.history
      else
        visited << [state.position, state.orientation]

        # try turning left
        new_orientation = turn_effect(state.orientation, 'left')
        unless visited.include? [state.position, new_orientation]
          new_state = State.new(state.position, new_orientation, state.history + ['left'])
          queue.push new_state, priority.(new_state)
        end

        # try turning right
        new_orientation = turn_effect(state.orientation, 'right')
        unless visited.include? [state.position, new_orientation]
          new_state = State.new(state.position, new_orientation, state.history + ['right'])
          queue.push new_state, priority.(new_state)
        end

        # try moving forward, if the way ahead is open
        new_position = wrap_add state.position, orientation_delta(state.orientation)
        return state.history + ['move'] if new_position == goal_pos
        if %w(_ B).include?(grid_at(new_position)) && !visited.include?([new_position, state.orientation])
          new_state = State.new(new_position, state.orientation, state.history + ['move'])
          queue.push new_state, priority.(new_state)
        end
      end
    end
    puts "A* failed to find path :("
    return ['noop']
  end

end

tank = Tank.new
tank.connect
tank.game_loop
