extends Control

@onready var input_screen:Control = $InputScreen
@onready var loading_screen:Control = $LoadingScreen
@onready var output_screen:Control = $OutputScreen

@onready var manual_csv_text_edit:TextEdit = $InputScreen/ManualCSVTextEdit
@onready var import_csv_button:Button = $InputScreen/ImportCSVButton
@onready var process_csv_button:Button = $InputScreen/ProcessCSVButton
@onready var file_dialog:FileDialog = $InputScreen/FileDialog
@onready var loading_text_edit:TextEdit = $LoadingScreen/LoadingTextEdit
@onready var loading_progress_bar:ProgressBar = $LoadingScreen/LoadingProgressBar
@onready var output_rich_text_label:RichTextLabel = $OutputScreen/OutputRichTextLabel
@onready var start_over_button:Button = $OutputScreen/StartOverButton

@onready var all_screens:Array[Control] = [
	input_screen,
	loading_screen,
	output_screen,
]

const CHANNEL_ID:String = 'channel_id'
const CHANNEL_NAME:String = 'channel_name'
const LATEST_VIDEO_DATE:String = 'latest_video_date'
const ERROR_STATE:String = 'error_state'

const MAX_ACTIVE_HTTP_REQUESTS:int = 5
var active_http_requests:Array[HTTPRequest] = []
var pending_channel_requests:Array[Dictionary] = []
var output_sub_data:Array[Dictionary] = []
var completed_requests:int = 0

# Called when the node enters the scene tree for the first time.
func _ready() -> void:
	process_csv_button.pressed.connect(_process_csv_text)
	import_csv_button.pressed.connect(_import_csv)
	start_over_button.pressed.connect(_start_over)
	output_rich_text_label.meta_clicked.connect(_open_url)
	file_dialog.file_selected.connect(_import_csv_file_selected)

func _open_url(meta:String) -> void:
	OS.shell_open(meta)

func _check_if_done_loading() -> void:
	var active_count:int = active_http_requests.size()
	var pending_count:int = pending_channel_requests.size()
	var total:int = completed_requests + active_count + pending_count
	loading_progress_bar.set_value_no_signal(float(completed_requests) / float(total))
	if pending_count > 0 or active_count > 0:
		var slots_available = MAX_ACTIVE_HTTP_REQUESTS - active_count
		while slots_available and pending_count:
			var pending:Dictionary = pending_channel_requests.pop_back()
			var channel_id:String = pending[CHANNEL_ID]
			var channel_name:String = pending[CHANNEL_NAME]
			var http_request:HTTPRequest = HTTPRequest.new()
			http_request.request_completed.connect(_handle_rss_response.bind(channel_id, channel_name, http_request), CONNECT_ONE_SHOT)
			add_child(http_request)
			http_request.request('https://www.youtube.com/feeds/videos.xml?channel_id=' + channel_id)
			active_http_requests.append(http_request)
			pending_count -= 1
			slots_available -= 1
	else:
		_show_output()

func _process_csv_text() -> void:
	pending_channel_requests = _parse_csv(manual_csv_text_edit.text)
	_show_loading()

func _handle_rss_response(_result:int, response_code:int, _headers: PackedStringArray, body: PackedByteArray, channel_id:String, channel_name:String, http_request:HTTPRequest) -> void:
	if response_code == 200:
		loading_text_edit.text += '%s%s: Loaded' % ['\n' if loading_text_edit.text else '', channel_name]
		# This is how it should be done... but it is too much work.
		#var xml_parser = XMLParser.new()
		#xml_parser.open_buffer(body)
		# Process via XML: body.get_string_from_utf8()
		var regex:RegEx = RegEx.new()
		regex.compile('<published>(?<date>[^<]+)<\\/published>')
		var matches:Array[RegExMatch] = regex.search_all(body.get_string_from_utf8())
		matches.sort_custom(func (a:RegExMatch, b:RegExMatch) -> bool:
			return a.get_string('date') > b.get_string('date'))
		output_sub_data.append({
			CHANNEL_NAME: channel_name,
			CHANNEL_ID: channel_id,
			ERROR_STATE: '',
			LATEST_VIDEO_DATE: matches[0].get_string('date'),
		})
	elif response_code == 404:
		loading_text_edit.text += '\n%s: Banned' % [channel_name]
		output_sub_data.append({
			CHANNEL_NAME: channel_name,
			CHANNEL_ID: channel_id,
			ERROR_STATE: 'BANNED',
			LATEST_VIDEO_DATE: '',
		})
	else:
		loading_text_edit.text += '\n%s: Unknown Error %s' % [channel_name, response_code]
		output_sub_data.append({
			CHANNEL_NAME: channel_name,
			CHANNEL_ID: channel_id,
			ERROR_STATE: 'UNKNOWN_ERROR',
			LATEST_VIDEO_DATE: '',
		})
	loading_text_edit.scroll_vertical = loading_text_edit.get_v_scroll_bar().max_value
	active_http_requests.remove_at(active_http_requests.find(http_request))
	completed_requests += 1
	_check_if_done_loading()

func _import_csv() -> void:
	file_dialog.call_deferred('show')

func _import_csv_file_selected(file_path:String) -> void:
	var file:FileAccess = FileAccess.open(file_path, FileAccess.READ)
	pending_channel_requests = _parse_csv(file.get_as_text())
	file.close()
	_show_loading()

func _show_single_screen(screen:Control) -> void:
	for control:Control in all_screens:
		control.hide()
	screen.show()

func _show_loading() -> void:
	completed_requests = 0
	loading_text_edit.clear()
	loading_text_edit.scroll_vertical = 0.0
	_show_single_screen(loading_screen)
	output_sub_data.clear()
	_check_if_done_loading()

func _show_output() -> void:
	output_sub_data.sort_custom(func (a:Dictionary, b:Dictionary) -> bool:
		if a[ERROR_STATE]:
			return true
		if b[ERROR_STATE]:
			return false
		return a[LATEST_VIDEO_DATE] > b[LATEST_VIDEO_DATE])
	for sub_data:Dictionary in output_sub_data:
		output_rich_text_label.append_text('%s [url=https://www.youtube.com/channel/%s]%s[/url]' % [sub_data[ERROR_STATE] if sub_data[ERROR_STATE] else ('last uploaded %s:' % [sub_data[LATEST_VIDEO_DATE].trim_suffix('+00:00')]), sub_data[CHANNEL_ID], sub_data[CHANNEL_NAME]])
		output_rich_text_label.newline()
	_show_single_screen(output_screen)

func _start_over() -> void:
	output_rich_text_label.clear()
	output_rich_text_label.scroll_to_line(0)
	_show_single_screen(input_screen)

func _parse_csv(text:String) -> Array[Dictionary]:
	var sub_data:Array[Dictionary] = []
	var lines:PackedStringArray = text.split("\n")
	for line:String in lines:
		line = line.strip_edges()
		if not line or line == 'Channel Id,Channel Url,Channel Title':
			continue
		var data = line.split(',')
		assert(data.size() == 3)
		var channel_id = data[0]
		var channel_name = data[2]
		sub_data.append({CHANNEL_ID: channel_id, CHANNEL_NAME: channel_name})
	return sub_data
