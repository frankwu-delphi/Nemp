var currentProgress=0;
var t;
var successBtn = "<img src='images/success.png' width='24' height='24' alt='operation: success' />"
var failBtn = "<img src='images/fail.png' width='24' height='24' alt='operation: failed' />"

$(document).ready(function() {			
	if ( $("#progress").length > 0 ) {
		$("#progress").slider({ stop: function(event, ui) { 				
			$.ajax({url:"playercontrolJS?action=setprogress&value="+ui.value, dataType:"html"});},
			animate: 1000					
			} );				
		t=setTimeout("checkProgress()",1000);
	};
	
	if ( $("#volume").length > 0 ){
		$("#volume").slider( 
				{ stop: function(event, ui){$.ajax({url:"playercontrolJS?action=setvolume&value="+ui.value, dataType:"html"});},
				  slide: function(event, ui){$.ajax({url:"playercontrolJS?action=setvolume&value="+ui.value, dataType:"html"}) }
				} 
			);
		checkVolume();
	}
});

function checkVolume() {
	$.ajax({url:"playercontrolJS?action=getvolume", dataType:"text", success: 
		function(data, textStatus, jqXHR){$("#volume").slider( "value" , data);}
		});				
}

function checkProgress(){
	$.ajax({url:"playercontrolJS?action=getprogress", dataType:"text", success: setslider});
};

function setslider(data, textStatus, jqXHR){
	if (currentProgress > data){
		// reload playerdata/controls
		$.ajax({url:"playercontrolJS?part=controls", dataType:"html", success: loadplayercontrols});
	}
	currentProgress = data;
	$("#progress").slider( "value" , data);
	
	if ( $("#progress").length > 0 ) {
			t=setTimeout("checkProgress()",1000);
		}
}

function playercontrol_VolumeUp() {
	$.ajax({url:"playercontrolJS?action=setvolume&value=1000", dataType:"html", success: checkVolume});	
  }
  
function playercontrol_VolumeDown() {
	$.ajax({url:"playercontrolJS?action=setvolume&value=-1000", dataType:"html", success: checkVolume});
  }
  
  

function loadplayercontrols(data, textStatus, jqXHR){			
	var	$currentDOM = $("#playercontrol");			
	$currentDOM.html(data);		
	$.ajax({url:"playercontrolJS?part=data", dataType:"html", success: loadplayerdata});						
};
		
function loadplayerdata(data, textStatus, jqXHR){			
	var	$currentDOM = $("#playerdata");
	$currentDOM.html(data);					
};
		
function playercontrol_playpause(){			
	$.ajax({url:"playercontrolJS?action=playpause&part=controls", dataType:"html", success: loadplayercontrols});					
};
function playercontrol_stop(){
	$.ajax({url:"playercontrolJS?action=stop&part=controls", dataType:"html", success: loadplayercontrols});		
};
function playercontrol_playnext(){
	$.ajax({url:"playercontrolJS?action=next&part=controls", dataType:"html", success: loadplayercontrols});		
};
function playercontrol_playprevious(){
	$.ajax({url:"playercontrolJS?action=previous&part=controls", dataType:"html", success: loadplayercontrols});		
};
		
	

function playtitle(aID){			
	$.ajax({url:"playlistcontrolJS?id="+aID+"&action=file_playnow", dataType:"html", success: showtest});		
	
	function showtest(data, textStatus, jqXHR)
	{ 				
		if (data == "0") {
			alert("Playing failed. Please reload this page and try again.");
		}				
		$(".current").removeClass("current");				
		$("#js"+data).addClass("current");
	}			
};

function reloadplaylist(){
	// alert("lade playlist neu");
	//document.location.reload(true);
	// document.location="playlist";
	$.ajax({url:"playlistcontrolJS?id=-1&action=loaditem", dataType:"html", success: replacePlaylist});
};		
function replacePlaylist(data, textStatus, jqXHR) {			
	$("#playlist").html(data);			
};

function moveup(aID){
	$.ajax({url:"playlistcontrolJS?id="+aID+"&action=file_moveup", dataType:"text", success: moveup2});
		
	function moveup2(data, textStatus, jqXHR) {		
		// moveup of a Prebooklist-Item. reloading playlist is recommended
		reloadplaylist();
	}		
};

function movedown(aID){	
	$.ajax({url:"playlistcontrolJS?id="+aID+"&action=file_movedown", dataType:"text", success: movedown2});
		
	function movedown2(data, textStatus, jqXHR) {		
						
			// movedown of a Prebooklist-Item. reloading playlist is recommended
			reloadplaylist();
	}
};

function filedelete(aID){
	$.ajax({url:"playlistcontrolJS?id="+aID+"&action=file_delete", dataType:"text", success: filedelete2});
	function filedelete2(data, textStatus, jqXHR){
		if (data == "1") {
			// delete item from DOM
			$("#js"+aID).remove();				
		} else
		{	// invalid item or prebook-delete => reload playlist
			reloadplaylist();
		}				
	}		
};

function addnext(aID){
	$.ajax({url:"playlistcontrolJS?id="+aID+"&action=file_addnext", dataType:"text", success: fileaddnext2});
	function fileaddnext2(data, textStatus, jqXHR){						
		if (data == "ok") { 
			$("#btnAddNext"+aID).html(successBtn); } 
		else {
			$("#btnAddNext"+aID).html(failBtn); }
		$("#btnAddNext"+aID).removeAttr('onclick');
		}
}

function add(aID){
	$.ajax({url:"playlistcontrolJS?id="+aID+"&action=file_add", dataType:"text", success: fileadd2});
	function fileadd2(data, textStatus, jqXHR){
		if (data == "ok") { 
			$("#btnAdd"+aID).html(successBtn); } 
		else {
			$("#btnAdd"+aID).html(failBtn); }
		$("#btnAdd"+aID).removeAttr('onclick');
	}
}

function vote(aID){
		$.ajax({url:"playlistcontrolJS?id="+aID+"&action=file_vote", dataType:"html", success: votereply});
		
		function votereply(data, textStatus, jqXHR){
			if (data == "ok") { 
				if ( $("#playlist").length > 0 ) {reloadplaylist();}
				else // replace ID with Success-button
					{ 
					$("#btnVote"+aID).html(successBtn);
					$("#btnVote"+aID).removeAttr('onclick');
					}
				} 
			else if (data == "already voted") { alert("You can't vote for the same file that fast again."); }
			else if (data == "spam") { alert("Don't you think you liked enough files for now? - Voting not accepted."); }
			else if (data == "exception") { alert("Failure. Please reload.");}
		}
}